require "digest"

module AnticipationRequests
  class IssueChallenges
    CONFIRMATION_PURPOSE = "ANTICIPATION_CONFIRMATION".freeze
    TARGET_TYPE = "AnticipationRequest".freeze
    PRIMARY_OUTBOX_EVENT_TYPE = "ANTICIPATION_CONFIRMATION_CHALLENGES_ISSUED".freeze
    EMAIL_OUTBOX_EVENT_TYPE = "AUTH_CHALLENGE_EMAIL_DISPATCH_REQUESTED".freeze
    WHATSAPP_OUTBOX_EVENT_TYPE = "AUTH_CHALLENGE_WHATSAPP_DISPATCH_REQUESTED".freeze
    CHALLENGE_TTL = 15.minutes
    CHALLENGE_CHANNELS = %w[EMAIL WHATSAPP].freeze

    IssueInputs = Struct.new(
      :anticipation_request_id,
      :email_destination,
      :whatsapp_destination,
      :payload_hash,
      keyword_init: true
    )

    Result = Struct.new(:anticipation_request, :challenges, :replayed, keyword_init: true) do
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

    def call(anticipation_request_id:, email_destination:, whatsapp_destination:)
      failure_logged = false
      inputs = build_issue_inputs(
        anticipation_request_id: anticipation_request_id,
        email_destination: email_destination,
        whatsapp_destination: whatsapp_destination
      )
      anticipation_request = nil
      result = nil
      validation_error = nil

      ActiveRecord::Base.transaction do
        anticipation_request = find_anticipation_request!(inputs.anticipation_request_id)
        result, validation_error = issue_or_replay_challenges!(
          anticipation_request: anticipation_request,
          inputs: inputs
        )
      end

      if validation_error
        create_failure_log(
          error: validation_error,
          anticipation_request_id: inputs.anticipation_request_id,
          actor_party_id: anticipation_request&.requester_party_id
        )
        failure_logged = true
        raise validation_error
      end

      result
    rescue ValidationError => error
      unless failure_logged
        create_failure_log(
          error: error,
          anticipation_request_id: inputs&.anticipation_request_id || anticipation_request_id,
          actor_party_id: anticipation_request&.requester_party_id
        )
      end
      raise
    rescue ActiveRecord::RecordNotFound => error
      create_failure_log(error:, anticipation_request_id: inputs&.anticipation_request_id || anticipation_request_id, actor_party_id: anticipation_request&.requester_party_id)
      raise
    rescue ActiveRecord::RecordNotUnique
      replay_after_unique_violation(payload_hash: inputs&.payload_hash.to_s)
    end

    private

    def replay_after_unique_violation(payload_hash:)
      existing_outbox = OutboxEvent.find_by!(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      replay_result(existing_outbox:, payload_hash: payload_hash)
    end

    def build_issue_inputs(anticipation_request_id:, email_destination:, whatsapp_destination:)
      normalized_email = normalize_email_destination(email_destination)
      normalized_whatsapp = normalize_whatsapp_destination(whatsapp_destination)
      payload_hash = issuance_payload_hash(
        anticipation_request_id: anticipation_request_id,
        email_destination: normalized_email,
        whatsapp_destination: normalized_whatsapp
      )

      IssueInputs.new(
        anticipation_request_id: anticipation_request_id,
        email_destination: normalized_email,
        whatsapp_destination: normalized_whatsapp,
        payload_hash: payload_hash
      )
    end

    def find_anticipation_request!(anticipation_request_id)
      AnticipationRequest.where(tenant_id: @tenant_id).lock.find(anticipation_request_id)
    end

    def issue_or_replay_challenges!(anticipation_request:, inputs:)
      return [ nil, status_not_challengeable_error ] unless anticipation_request.status == "REQUESTED"

      existing_outbox = OutboxEvent.lock.find_by(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      return [ replay_result(existing_outbox:, payload_hash: inputs.payload_hash), nil ] if existing_outbox

      [ issue_new_challenges!(anticipation_request:, inputs:), nil ]
    rescue ValidationError => error
      [ nil, error ]
    end

    def status_not_challengeable_error
      ValidationError.new(
        code: "anticipation_status_not_challengeable",
        message: "Only REQUESTED anticipation requests can issue confirmation challenges."
      )
    end

    def issue_new_challenges!(anticipation_request:, inputs:)
      email_code = generate_code
      whatsapp_code = generate_code
      expires_at = Time.current + CHALLENGE_TTL

      email_challenge, whatsapp_challenge = create_confirmation_challenge_pair!(
        anticipation_request: anticipation_request,
        inputs: inputs,
        email_code: email_code,
        whatsapp_code: whatsapp_code,
        expires_at: expires_at
      )

      create_primary_outbox_event!(
        anticipation_request: anticipation_request,
        payload_hash: inputs.payload_hash,
        email_challenge: email_challenge,
        whatsapp_challenge: whatsapp_challenge
      )
      create_channel_outbox_event!(
        anticipation_request: anticipation_request,
        challenge: email_challenge,
        event_type: EMAIL_OUTBOX_EVENT_TYPE,
        idempotency_key_suffix: "email",
        destination: inputs.email_destination,
        code: email_code
      )
      create_channel_outbox_event!(
        anticipation_request: anticipation_request,
        challenge: whatsapp_challenge,
        event_type: WHATSAPP_OUTBOX_EVENT_TYPE,
        idempotency_key_suffix: "whatsapp",
        destination: inputs.whatsapp_destination,
        code: whatsapp_code
      )
      create_receivable_event!(
        anticipation_request: anticipation_request,
        email_challenge: email_challenge,
        whatsapp_challenge: whatsapp_challenge
      )
      create_action_log!(
        action_type: "ANTICIPATION_CHALLENGES_ISSUED",
        success: true,
        requester_party_id: anticipation_request.requester_party_id,
        target_id: anticipation_request.id,
        metadata: {
          replayed: false,
          idempotency_key: @idempotency_key,
          challenge_ids: [ email_challenge.id, whatsapp_challenge.id ]
        }
      )

      Result.new(
        anticipation_request: anticipation_request,
        challenges: [ email_challenge, whatsapp_challenge ],
        replayed: false
      )
    end

    def create_confirmation_challenge_pair!(anticipation_request:, inputs:, email_code:, whatsapp_code:, expires_at:)
      email_challenge = create_challenge!(
        anticipation_request: anticipation_request,
        delivery_channel: "EMAIL",
        destination_masked: mask_email(inputs.email_destination),
        code: email_code,
        expires_at: expires_at
      )
      whatsapp_challenge = create_challenge!(
        anticipation_request: anticipation_request,
        delivery_channel: "WHATSAPP",
        destination_masked: mask_whatsapp(inputs.whatsapp_destination),
        code: whatsapp_code,
        expires_at: expires_at
      )

      [ email_challenge, whatsapp_challenge ]
    end

    def replay_result(existing_outbox:, payload_hash:)
      existing_payload_hash = existing_outbox.payload&.dig("payload_hash").to_s
      if existing_payload_hash.present? && existing_payload_hash != payload_hash
        raise IdempotencyConflict.new(
          code: "idempotency_key_reused_with_different_payload",
          message: "Idempotency-Key was already used with a different challenge issuance payload."
        )
      end

      anticipation_request = AnticipationRequest.where(tenant_id: @tenant_id).find(existing_outbox.aggregate_id)
      challenge_ids = Array(existing_outbox.payload&.dig("challenge_ids"))
      challenges = AuthChallenge.where(tenant_id: @tenant_id, id: challenge_ids).order(delivery_channel: :asc)

      create_action_log!(
        action_type: "ANTICIPATION_CHALLENGES_REPLAYED",
        success: true,
        requester_party_id: anticipation_request.requester_party_id,
        target_id: anticipation_request.id,
        metadata: { replayed: true, idempotency_key: @idempotency_key }
      )

      Result.new(anticipation_request:, challenges: challenges.to_a, replayed: true)
    end

    def create_challenge!(anticipation_request:, delivery_channel:, destination_masked:, code:, expires_at:)
      AuthChallenge.create!(
        tenant_id: @tenant_id,
        actor_party_id: anticipation_request.requester_party_id,
        purpose: CONFIRMATION_PURPOSE,
        delivery_channel: delivery_channel,
        destination_masked: destination_masked,
        code_digest: digest(code),
        status: "PENDING",
        attempts: 0,
        max_attempts: 5,
        expires_at: expires_at,
        request_id: @request_id,
        target_type: TARGET_TYPE,
        target_id: anticipation_request.id,
        metadata: {
          "issued_via" => "API",
          "issue_idempotency_key" => @idempotency_key
        }
      )
    end

    def create_primary_outbox_event!(anticipation_request:, payload_hash:, email_challenge:, whatsapp_challenge:)
      OutboxEvent.create!(
        tenant_id: @tenant_id,
        aggregate_type: TARGET_TYPE,
        aggregate_id: anticipation_request.id,
        event_type: PRIMARY_OUTBOX_EVENT_TYPE,
        status: "PENDING",
        idempotency_key: @idempotency_key,
        payload: {
          "payload_hash" => payload_hash
        }.merge(challenge_reference_payload(email_challenge:, whatsapp_challenge:))
      )
    end

    def create_channel_outbox_event!(
      anticipation_request:,
      challenge:,
      event_type:,
      idempotency_key_suffix:,
      destination:,
      code:
    )
      OutboxEvent.create!(
        tenant_id: @tenant_id,
        aggregate_type: TARGET_TYPE,
        aggregate_id: anticipation_request.id,
        event_type: event_type,
        status: "PENDING",
        idempotency_key: "#{@idempotency_key}:#{idempotency_key_suffix}",
        payload: {
          "challenge_id" => challenge.id,
          "purpose" => CONFIRMATION_PURPOSE,
          "destination" => destination,
          "destination_masked" => challenge.destination_masked,
          "code" => code,
          "expires_at" => challenge.expires_at.utc.iso8601(6),
          "request_id" => @request_id
        }
      )
    end

    def create_receivable_event!(anticipation_request:, email_challenge:, whatsapp_challenge:)
      receivable = anticipation_request.receivable
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous[0] + 1 : 1
      prev_hash = previous&.[](1)
      occurred_at = Time.current

      payload = {
        anticipation_request_id: anticipation_request.id,
        idempotency_key: @idempotency_key
      }.merge(challenge_reference_payload(email_challenge:, whatsapp_challenge:, stringify_keys: false))
      event_type = "ANTICIPATION_CONFIRMATION_CHALLENGES_ISSUED"

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

    def challenge_reference_payload(email_challenge:, whatsapp_challenge:, stringify_keys: true)
      payload = {
        challenge_ids: [ email_challenge.id, whatsapp_challenge.id ],
        channels: CHALLENGE_CHANNELS
      }
      return payload unless stringify_keys

      payload.transform_keys(&:to_s)
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
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        actor_party_id: actor_party_id,
        action_type: "ANTICIPATION_CHALLENGES_ISSUE_FAILED",
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
        metadata: {
          "idempotency_key" => @idempotency_key,
          "error_class" => error.class.name,
          "error_code" => error.respond_to?(:code) ? error.code : "not_found",
          "error_message" => error.message
        }
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => log_error
      Rails.logger.error(
        "anticipation_challenges_issue_failure_log_write_error " \
        "error_class=#{log_error.class.name} error_message=#{log_error.message} " \
        "original_error_class=#{error.class.name} request_id=#{@request_id}"
      )
      nil
    end

    def normalize_email_destination(raw_email)
      email = raw_email.to_s.strip.downcase
      raise_validation_error!("invalid_email_destination", "email_destination is invalid.") if email.blank?
      raise_validation_error!("invalid_email_destination", "email_destination is invalid.") unless email.include?("@")

      email
    end

    def normalize_whatsapp_destination(raw_whatsapp)
      digits = raw_whatsapp.to_s.gsub(/\D+/, "")
      raise_validation_error!("invalid_whatsapp_destination", "whatsapp_destination is invalid.") if digits.length < 10

      digits
    end

    def mask_email(email)
      local, domain = email.split("@", 2)
      return "***" if local.blank? || domain.blank?

      domain_name, tld = domain.split(".", 2)
      "#{local[0]}***@#{domain_name.to_s[0]}***#{tld.present? ? ".#{tld}" : ""}"
    end

    def mask_whatsapp(digits)
      return "***" if digits.blank?

      tail = digits[-3, 3]
      prefix = digits[0, 2]
      "+#{prefix}*******#{tail}"
    end

    def generate_code
      format("%06d", SecureRandom.random_number(1_000_000))
    end

    def issuance_payload_hash(anticipation_request_id:, email_destination:, whatsapp_destination:)
      Digest::SHA256.hexdigest(
        canonical_json(
          anticipation_request_id: anticipation_request_id.to_s,
          email_destination: email_destination,
          whatsapp_destination: whatsapp_destination
        )
      )
    end

    def digest(raw_value)
      Digest::SHA256.hexdigest(raw_value.to_s)
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
