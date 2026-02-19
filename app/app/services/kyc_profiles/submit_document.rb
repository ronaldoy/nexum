require "digest"

module KycProfiles
  class SubmitDocument
    OUTBOX_EVENT_TYPE = "KYC_DOCUMENT_SUBMITTED".freeze
    TARGET_TYPE = "KycProfile".freeze
    PAYLOAD_HASH_KEY = "payload_hash".freeze
    DEFAULT_CLIENT_METADATA_KEYS = %w[
      source
      source_system
      source_channel
      source_reference
      integration_reference
    ].freeze

    Result = Struct.new(:kyc_document, :replayed, keyword_init: true) do
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

    def call(kyc_profile_id:, raw_payload:)
      payload = raw_payload.to_h.deep_symbolize_keys
      normalized_payload = normalize_payload(payload)
      payload_hash = build_payload_hash(kyc_profile_id: kyc_profile_id, payload: normalized_payload.except(:blob))

      kyc_document = nil
      result = nil
      validation_error = nil

      ActiveRecord::Base.transaction do
        existing_outbox = OutboxEvent.lock.find_by(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
        if existing_outbox
          begin
            result = replay_result(existing_outbox:, payload_hash:)
          rescue ValidationError => error
            validation_error = error
          end
          next
        end

        kyc_profile = KycProfile.where(tenant_id: @tenant_id).lock.find(kyc_profile_id)
        validate_party_consistency!(kyc_profile:, payload: normalized_payload)

        kyc_document = KycDocument.create!(
          tenant_id: @tenant_id,
          kyc_profile: kyc_profile,
          party_id: kyc_profile.party_id,
          document_type: normalized_payload[:document_type],
          document_number: normalized_payload[:document_number],
          issuing_country: normalized_payload[:issuing_country],
          issuing_state: normalized_payload[:issuing_state],
          issued_on: normalized_payload[:issued_on],
          expires_on: normalized_payload[:expires_on],
          is_key_document: normalized_payload[:is_key_document],
          status: "SUBMITTED",
          storage_key: normalized_payload[:storage_key],
          sha256: normalized_payload[:sha256],
          metadata: normalized_payload[:metadata]
        )
        attach_blob!(record: kyc_document, blob: normalized_payload[:blob])

        create_kyc_event!(
          kyc_profile: kyc_profile,
          party_id: kyc_profile.party_id,
          event_type: OUTBOX_EVENT_TYPE,
          payload: {
            "idempotency_key" => @idempotency_key,
            "kyc_document_id" => kyc_document.id,
            "document_type" => kyc_document.document_type,
            "is_key_document" => kyc_document.is_key_document,
            "status" => kyc_document.status
          }
        )

        create_outbox_event!(
          kyc_profile: kyc_profile,
          kyc_document: kyc_document,
          payload_hash: payload_hash
        )

        create_action_log!(
          action_type: "KYC_DOCUMENT_SUBMITTED",
          success: true,
          actor_party_id: kyc_profile.party_id,
          target_id: kyc_document.id,
          metadata: {
            replayed: false,
            idempotency_key: @idempotency_key,
            kyc_profile_id: kyc_profile.id
          }
        )

        result = Result.new(kyc_document: kyc_document, replayed: false)
      end

      if validation_error
        create_failure_log(error: validation_error, target_id: kyc_profile_id, actor_party_id: nil)
        raise validation_error
      end

      result
    rescue ActiveRecord::RecordInvalid => error
      validation_error = ValidationError.new(
        code: "invalid_kyc_document",
        message: error.record.errors.full_messages.to_sentence
      )
      create_failure_log(error: validation_error, target_id: kyc_profile_id, actor_party_id: nil)
      raise validation_error
    rescue ActiveRecord::RecordNotFound => error
      create_failure_log(error: error, target_id: kyc_profile_id, actor_party_id: nil)
      raise
    rescue ActiveRecord::RecordNotUnique
      existing_outbox = OutboxEvent.find_by!(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      replay_result(existing_outbox:, payload_hash:)
    end

    private

    def normalize_payload(payload)
      metadata = sanitize_client_metadata(payload[:metadata] || {})

      blob = resolve_blob(raw_signed_id: payload[:blob_signed_id])
      validate_blob_tenant_metadata!(blob:) if blob.present?
      storage_key = payload[:storage_key].to_s.strip
      storage_key = blob.key if storage_key.blank? && blob.present?

      if blob.present? && payload[:storage_key].to_s.strip.present? && payload[:storage_key].to_s.strip != blob.key
        raise_validation_error!("storage_key_blob_mismatch", "storage_key does not match blob key.")
      end

      {
        party_id: payload[:party_id].presence&.to_s,
        document_type: payload[:document_type].to_s.upcase,
        document_number: payload[:document_number].presence&.to_s,
        issuing_country: (payload[:issuing_country].presence || "BR").to_s.upcase,
        issuing_state: payload[:issuing_state].presence&.to_s&.upcase,
        issued_on: parse_date(payload[:issued_on], field: "issued_on"),
        expires_on: parse_date(payload[:expires_on], field: "expires_on"),
        is_key_document: parse_boolean(payload.fetch(:is_key_document, false)),
        storage_key: storage_key,
        blob: blob,
        sha256: payload[:sha256].to_s,
        metadata: metadata
      }
    end

    def sanitize_client_metadata(raw_metadata)
      metadata = normalize_metadata(raw_metadata)
      unless metadata.is_a?(Hash)
        raise_validation_error!("invalid_metadata", "metadata must be a JSON object.")
      end

      MetadataSanitizer.sanitize(
        metadata,
        allowed_keys: allowed_client_metadata_keys
      )
    end

    def allowed_client_metadata_keys
      configured = Rails.app.creds.option(
        :security,
        :kyc_document_metadata_allowed_keys,
        default: ENV["KYC_DOCUMENT_METADATA_ALLOWED_KEYS"]
      )
      keys = Array(configured).flat_map { |value| value.to_s.split(",") }.map { |value| value.strip }.reject(&:blank?)
      keys.presence || DEFAULT_CLIENT_METADATA_KEYS
    end

    def parse_date(raw_date, field:)
      return nil if raw_date.blank?

      Date.iso8601(raw_date.to_s)
    rescue ArgumentError
      raise_validation_error!("invalid_#{field}", "#{field} is invalid.")
    end

    def resolve_blob(raw_signed_id:)
      signed_id = raw_signed_id.to_s.strip
      return nil if signed_id.blank?

      ActiveStorage::Blob.find_signed!(signed_id)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      raise_validation_error!("invalid_blob_signed_id", "blob_signed_id is invalid.")
    end

    def attach_blob!(record:, blob:)
      return if blob.blank?

      record.file.attach(blob)
    end

    def validate_blob_tenant_metadata!(blob:)
      metadata_tenant_id = blob.metadata&.dig("tenant_id").to_s.strip
      if metadata_tenant_id.blank?
        raise_validation_error!("missing_blob_tenant_metadata", "blob metadata tenant is required.")
      end
      return if metadata_tenant_id == @tenant_id.to_s

      raise_validation_error!("blob_tenant_mismatch", "blob metadata tenant does not match request tenant.")
    end

    def parse_boolean(raw_value)
      return raw_value if raw_value == true || raw_value == false
      return true if %w[true 1 yes y].include?(raw_value.to_s.strip.downcase)
      return false if %w[false 0 no n].include?(raw_value.to_s.strip.downcase)

      raise_validation_error!("invalid_is_key_document", "is_key_document is invalid.")
    end

    def validate_party_consistency!(kyc_profile:, payload:)
      return if payload[:party_id].blank?
      return if payload[:party_id] == kyc_profile.party_id

      raise_validation_error!("party_mismatch", "party_id must match the KYC profile party.")
    end

    def replay_result(existing_outbox:, payload_hash:)
      unless existing_outbox.event_type == OUTBOX_EVENT_TYPE && existing_outbox.aggregate_type == TARGET_TYPE
        raise IdempotencyConflict.new(
          code: "idempotency_key_reused_with_different_operation",
          message: "Idempotency-Key was already used with a different operation."
        )
      end

      existing_payload_hash = existing_outbox.payload&.dig(PAYLOAD_HASH_KEY).to_s
      if existing_payload_hash.present? && existing_payload_hash != payload_hash
        raise IdempotencyConflict.new(
          code: "idempotency_key_reused_with_different_payload",
          message: "Idempotency-Key was already used with a different payload."
        )
      end

      kyc_document_id = existing_outbox.payload&.dig("kyc_document_id")
      raise_validation_error!("replay_document_not_found", "Replay document was not found.") if kyc_document_id.blank?

      kyc_document = KycDocument.where(tenant_id: @tenant_id).find(kyc_document_id)
      create_action_log!(
        action_type: "KYC_DOCUMENT_REPLAYED",
        success: true,
        actor_party_id: kyc_document.party_id,
        target_id: kyc_document.id,
        metadata: { replayed: true, idempotency_key: @idempotency_key }
      )

      Result.new(kyc_document: kyc_document, replayed: true)
    end

    def create_kyc_event!(kyc_profile:, party_id:, event_type:, payload:)
      KycEvent.create!(
        tenant_id: @tenant_id,
        kyc_profile: kyc_profile,
        party_id: party_id,
        actor_party_id: Current.user&.party_id,
        event_type: event_type,
        occurred_at: Time.current,
        request_id: @request_id,
        payload: normalize_metadata(payload)
      )
    end

    def create_outbox_event!(kyc_profile:, kyc_document:, payload_hash:)
      OutboxEvent.create!(
        tenant_id: @tenant_id,
        aggregate_type: TARGET_TYPE,
        aggregate_id: kyc_profile.id,
        event_type: OUTBOX_EVENT_TYPE,
        status: "PENDING",
        idempotency_key: @idempotency_key,
        payload: {
          PAYLOAD_HASH_KEY => payload_hash,
          "kyc_profile_id" => kyc_profile.id,
          "kyc_document_id" => kyc_document.id
        }
      )
    end

    def create_action_log!(action_type:, success:, actor_party_id:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        actor_party_id: actor_party_id,
        action_type: action_type,
        ip_address: @request_ip.presence || "0.0.0.0",
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: "API",
        target_type: "KycDocument",
        target_id: target_id,
        success: success,
        occurred_at: Time.current,
        metadata: normalize_metadata(metadata)
      )
    end

    def create_failure_log(error:, target_id:, actor_party_id:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        actor_party_id: actor_party_id,
        action_type: "KYC_DOCUMENT_SUBMIT_FAILED",
        ip_address: @request_ip.presence || "0.0.0.0",
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: "API",
        target_type: TARGET_TYPE,
        target_id: target_id,
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
        "kyc_document_submit_failure_log_write_error " \
        "error_class=#{log_error.class.name} error_message=#{log_error.message} " \
        "original_error_class=#{error.class.name} request_id=#{@request_id}"
      )
      nil
    end

    def build_payload_hash(kyc_profile_id:, payload:)
      Digest::SHA256.hexdigest(
        canonical_json(
          kyc_profile_id: kyc_profile_id.to_s,
          payload: payload
        )
      )
    end

    def canonical_json(value)
      CanonicalJson.encode(value)
    end

    def normalize_metadata(raw_metadata)
      case raw_metadata
      when ActionController::Parameters
        normalize_metadata(raw_metadata.to_unsafe_h)
      when Hash
        raw_metadata.each_with_object({}) do |(key, value), output|
          output[key.to_s] = normalize_metadata(value)
        end
      when Array
        raw_metadata.map { |entry| normalize_metadata(entry) }
      else
        raw_metadata
      end
    end

    def raise_validation_error!(code, message)
      raise ValidationError.new(code: code, message: message)
    end
  end
end
