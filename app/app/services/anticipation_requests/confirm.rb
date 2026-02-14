require "digest"

module AnticipationRequests
  class Confirm
    CONFIRMATION_PURPOSE = "ANTICIPATION_CONFIRMATION".freeze
    TARGET_TYPE = "AnticipationRequest".freeze
    PAYLOAD_HASH_METADATA_KEY = "_confirmation_payload_hash".freeze

    Result = Struct.new(:anticipation_request, :replayed, keyword_init: true) do
      def replayed?
        replayed
      end
    end

    class ValidationError < StandardError
      attr_reader :code

      def initialize(code:, message:)
        super(message)
        @code = code
      end
    end

    class IdempotencyConflict < ValidationError; end

    def initialize(
      tenant_id:,
      actor_role:,
      request_id:,
      idempotency_key:,
      request_ip:,
      user_agent:,
      endpoint_path:,
      http_method:
    )
      @tenant_id = tenant_id
      @actor_role = actor_role
      @request_id = request_id
      @idempotency_key = idempotency_key
      @request_ip = request_ip
      @user_agent = user_agent
      @endpoint_path = endpoint_path
      @http_method = http_method
    end

    def call(anticipation_request_id:, email_code:, whatsapp_code:)
      payload_hash = confirmation_payload_hash(email_code:, whatsapp_code:)
      anticipation_request = nil
      result = nil
      validation_error = nil

      ActiveRecord::Base.transaction do
        anticipation_request = AnticipationRequest.where(tenant_id: @tenant_id).lock.find(anticipation_request_id)

        if anticipation_request.status == "APPROVED"
          begin
            ensure_replay_compatibility!(anticipation_request:, payload_hash:)
          rescue ValidationError => error
            validation_error = error
            next
          end
          create_action_log!(
            action_type: "ANTICIPATION_CONFIRM_REPLAYED",
            success: true,
            requester_party_id: anticipation_request.requester_party_id,
            target_id: anticipation_request.id,
            metadata: { replayed: true, idempotency_key: @idempotency_key }
          )
          result = Result.new(anticipation_request:, replayed: true)
          next
        end

        unless anticipation_request.status == "REQUESTED"
          validation_error = ValidationError.new(
            code: "anticipation_status_not_confirmable",
            message: "Only REQUESTED anticipation requests can be confirmed."
          )
          next
        end

        begin
          email_challenge = load_challenge!(
            anticipation_request: anticipation_request,
            channel: "EMAIL"
          )
          whatsapp_challenge = load_challenge!(
            anticipation_request: anticipation_request,
            channel: "WHATSAPP"
          )

          verify_challenge!(challenge: email_challenge, code: email_code, invalid_code: "invalid_email_code")
          verify_challenge!(challenge: whatsapp_challenge, code: whatsapp_code, invalid_code: "invalid_whatsapp_code")

          confirmed_at = Time.current
          anticipation_request.transition_status!(
            "APPROVED",
            metadata: {
              "confirmed_at" => confirmed_at.utc.iso8601(6),
              "confirmation_channels" => %w[EMAIL WHATSAPP],
              "confirmation_idempotency_key" => @idempotency_key,
              PAYLOAD_HASH_METADATA_KEY => payload_hash
            }
          )

          create_receivable_event!(
            anticipation_request: anticipation_request,
            email_challenge: email_challenge,
            whatsapp_challenge: whatsapp_challenge,
            occurred_at: confirmed_at
          )

          create_action_log!(
            action_type: "ANTICIPATION_CONFIRMED",
            success: true,
            requester_party_id: anticipation_request.requester_party_id,
            target_id: anticipation_request.id,
            metadata: {
              replayed: false,
              idempotency_key: @idempotency_key,
              confirmation_channels: %w[EMAIL WHATSAPP]
            }
          )

          result = Result.new(anticipation_request:, replayed: false)
        rescue ValidationError => error
          validation_error = error
        end
      end

      if validation_error
        create_failure_log(
          error: validation_error,
          anticipation_request_id: anticipation_request_id,
          actor_party_id: anticipation_request&.requester_party_id
        )
        raise validation_error
      end

      result
    rescue ActiveRecord::RecordNotFound => error
      create_failure_log(error:, anticipation_request_id:, actor_party_id: anticipation_request&.requester_party_id)
      raise
    end

    private

    def load_challenge!(anticipation_request:, channel:)
      challenge = AuthChallenge.where(
        tenant_id: @tenant_id,
        actor_party_id: anticipation_request.requester_party_id,
        purpose: CONFIRMATION_PURPOSE,
        delivery_channel: channel,
        target_type: TARGET_TYPE,
        target_id: anticipation_request.id
      ).where(status: %w[PENDING VERIFIED]).order(created_at: :desc).lock(true).first

      return challenge if challenge

      raise_validation_error!(
        "missing_#{channel.downcase}_challenge",
        "Missing #{channel.downcase} challenge."
      )
    end

    def verify_challenge!(challenge:, code:, invalid_code:)
      return if challenge.status == "VERIFIED"

      if code.to_s.strip.blank?
        raise_validation_error!(invalid_code, "Confirmation code is required.")
      end

      if challenge.expires_at <= Time.current
        challenge.update!(status: "EXPIRED")
        raise_validation_error!("challenge_expired", "Confirmation challenge is expired.")
      end

      attempts = challenge.attempts + 1
      if secure_compare_digest(digest(code), challenge.code_digest)
        challenge.update!(status: "VERIFIED", consumed_at: Time.current, attempts: attempts)
      else
        updates = { attempts: attempts }
        if attempts >= challenge.max_attempts
          updates[:status] = "CANCELLED"
          challenge.update!(updates)
          raise_validation_error!("challenge_attempts_exceeded", "Confirmation challenge exceeded maximum attempts.")
        end

        challenge.update!(updates)
        raise_validation_error!(invalid_code, "Confirmation code is invalid.")
      end
    end

    def ensure_replay_compatibility!(anticipation_request:, payload_hash:)
      stored_hash = anticipation_request.metadata&.[](PAYLOAD_HASH_METADATA_KEY).to_s
      return if stored_hash.blank? || stored_hash == payload_hash

      raise IdempotencyConflict.new(
        code: "idempotency_key_reused_with_different_payload",
        message: "Idempotency-Key was already used with a different confirmation payload."
      )
    end

    def create_receivable_event!(anticipation_request:, email_challenge:, whatsapp_challenge:, occurred_at:)
      receivable = anticipation_request.receivable
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous[0] + 1 : 1
      prev_hash = previous&.[](1)
      event_type = "ANTICIPATION_CONFIRMED"

      payload = {
        anticipation_request_id: anticipation_request.id,
        idempotency_key: @idempotency_key,
        confirmation_channels: %w[EMAIL WHATSAPP],
        email_challenge_id: email_challenge.id,
        whatsapp_challenge_id: whatsapp_challenge.id
      }

      event_hash = Digest::SHA256.hexdigest(
        canonical_json(
          receivable_id: receivable.id,
          sequence: sequence,
          event_type: event_type,
          occurred_at: occurred_at.utc.iso8601(6),
          request_id: @request_id,
          prev_hash: prev_hash,
          payload: payload
        )
      )

      ReceivableEvent.create!(
        tenant_id: @tenant_id,
        receivable: receivable,
        sequence: sequence,
        event_type: event_type,
        actor_party_id: anticipation_request.requester_party_id,
        actor_role: @actor_role,
        occurred_at: occurred_at,
        request_id: @request_id,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: payload
      )
    end

    def create_action_log!(action_type:, success:, requester_party_id:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        actor_party_id: requester_party_id,
        action_type: action_type,
        ip_address: @request_ip.presence || "0.0.0.0",
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: "API",
        target_type: TARGET_TYPE,
        target_id: target_id,
        success: success,
        occurred_at: Time.current,
        metadata: normalized_metadata(metadata)
      )
    end

    def create_failure_log(error:, anticipation_request_id:, actor_party_id:)
      metadata = {
        replayed: false,
        idempotency_key: @idempotency_key,
        error_class: error.class.name,
        error_code: error.respond_to?(:code) ? error.code : "not_found",
        error_message: error.message
      }

      ActionIpLog.create!(
        tenant_id: @tenant_id,
        actor_party_id: actor_party_id,
        action_type: "ANTICIPATION_CONFIRM_FAILED",
        ip_address: @request_ip.presence || "0.0.0.0",
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: "API",
        target_type: TARGET_TYPE,
        target_id: anticipation_request_id,
        success: false,
        occurred_at: Time.current,
        metadata: metadata
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => log_error
      Rails.logger.error(
        "anticipation_confirm_failure_log_write_error " \
        "error_class=#{log_error.class.name} error_message=#{log_error.message} " \
        "original_error_class=#{error.class.name} request_id=#{@request_id}"
      )
      nil
    end

    def confirmation_payload_hash(email_code:, whatsapp_code:)
      Digest::SHA256.hexdigest(
        canonical_json(
          email_code: email_code.to_s.strip,
          whatsapp_code: whatsapp_code.to_s.strip
        )
      )
    end

    def digest(raw_value)
      Digest::SHA256.hexdigest(raw_value.to_s.strip)
    end

    def secure_compare_digest(left, right)
      return false if left.blank? || right.blank?
      return false unless left.bytesize == right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def canonical_json(value)
      CanonicalJson.encode(value)
    end

    def normalized_metadata(raw_metadata)
      case raw_metadata
      when ActionController::Parameters
        normalized_metadata(raw_metadata.to_unsafe_h)
      when Hash
        raw_metadata.each_with_object({}) do |(key, value), output|
          output[key.to_s] = normalized_metadata(value)
        end
      when Array
        raw_metadata.map { |entry| normalized_metadata(entry) }
      else
        raw_metadata
      end
    end

    def raise_validation_error!(code, message)
      raise ValidationError.new(code:, message:)
    end
  end
end
