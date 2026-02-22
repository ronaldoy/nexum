require "digest"

module KycProfiles
  class SubmitDocument
    include Idempotency::OutboxReplayValidation
    include DirectUploads::BlobValidation
    include Metadata::ClientMetadataSanitization

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
    SubmissionInputs = Struct.new(:kyc_profile_id, :normalized_payload, :payload_hash, keyword_init: true)

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
      inputs = build_submission_inputs(kyc_profile_id:, raw_payload:)
      ActiveRecord::Base.transaction do
        submit_or_replay(inputs)
      end
    rescue ValidationError => error
      failure_target_id = resolve_failure_target_id(inputs: inputs, fallback_kyc_profile_id: kyc_profile_id)
      create_failure_log(error: error, target_id: failure_target_id, actor_party_id: nil)
      raise
    rescue ActiveRecord::RecordInvalid => error
      validation_error = ValidationError.new(
        code: "invalid_kyc_document",
        message: error.record.errors.full_messages.to_sentence
      )
      failure_target_id = resolve_failure_target_id(inputs: inputs, fallback_kyc_profile_id: kyc_profile_id)
      create_failure_log(error: validation_error, target_id: failure_target_id, actor_party_id: nil)
      raise validation_error
    rescue ActiveRecord::RecordNotFound => error
      failure_target_id = resolve_failure_target_id(inputs: inputs, fallback_kyc_profile_id: kyc_profile_id)
      create_failure_log(error: error, target_id: failure_target_id, actor_party_id: nil)
      raise
    rescue ActiveRecord::RecordNotUnique
      existing_outbox = OutboxEvent.find_by!(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      replay_result(existing_outbox:, payload_hash: inputs&.payload_hash.to_s)
    end

    private

    def resolve_failure_target_id(inputs:, fallback_kyc_profile_id:)
      inputs&.kyc_profile_id || fallback_kyc_profile_id
    end

    def build_submission_inputs(kyc_profile_id:, raw_payload:)
      payload = raw_payload.to_h.deep_symbolize_keys
      normalized_payload = normalize_payload(payload)
      payload_hash = build_payload_hash(kyc_profile_id: kyc_profile_id, payload: normalized_payload.except(:blob))

      SubmissionInputs.new(
        kyc_profile_id: kyc_profile_id,
        normalized_payload: normalized_payload,
        payload_hash: payload_hash
      )
    end

    def submit_or_replay(inputs)
      existing_outbox = OutboxEvent.lock.find_by(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      return replay_result(existing_outbox:, payload_hash: inputs.payload_hash) if existing_outbox

      create_submission_result!(inputs)
    end

    def create_submission_result!(inputs)
      kyc_profile = KycProfile.where(tenant_id: @tenant_id).lock.find(inputs.kyc_profile_id)
      validate_party_consistency!(kyc_profile:, payload: inputs.normalized_payload)
      validate_blob_actor_party_metadata!(
        blob: inputs.normalized_payload[:blob],
        expected_actor_party_id: kyc_profile.party_id
      )

      kyc_document = persist_kyc_document!(kyc_profile:, payload: inputs.normalized_payload)
      append_submission_artifacts!(kyc_profile:, kyc_document:, payload_hash: inputs.payload_hash)
      log_submission_success!(kyc_profile:, kyc_document:)

      Result.new(kyc_document:, replayed: false)
    end

    def persist_kyc_document!(kyc_profile:, payload:)
      kyc_document = KycDocument.create!(
        tenant_id: @tenant_id,
        kyc_profile: kyc_profile,
        party_id: kyc_profile.party_id,
        document_type: payload[:document_type],
        document_number: payload[:document_number],
        issuing_country: payload[:issuing_country],
        issuing_state: payload[:issuing_state],
        issued_on: payload[:issued_on],
        expires_on: payload[:expires_on],
        is_key_document: payload[:is_key_document],
        status: "SUBMITTED",
        storage_key: payload[:storage_key],
        sha256: payload[:sha256],
        metadata: payload[:metadata]
      )
      attach_blob!(record: kyc_document, blob: payload[:blob])
      kyc_document
    end

    def append_submission_artifacts!(kyc_profile:, kyc_document:, payload_hash:)
      create_kyc_event!(
        kyc_profile: kyc_profile,
        party_id: kyc_profile.party_id,
        event_type: OUTBOX_EVENT_TYPE,
        payload: submission_event_payload(kyc_document)
      )

      create_outbox_event!(
        kyc_profile: kyc_profile,
        kyc_document: kyc_document,
        payload_hash: payload_hash
      )
    end

    def submission_event_payload(kyc_document)
      {
        "idempotency_key" => @idempotency_key,
        "kyc_document_id" => kyc_document.id,
        "document_type" => kyc_document.document_type,
        "is_key_document" => kyc_document.is_key_document,
        "status" => kyc_document.status
      }
    end

    def log_submission_success!(kyc_profile:, kyc_document:)
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
    end

    def normalize_payload(payload)
      metadata = sanitize_client_metadata(payload[:metadata] || {})

      blob = resolve_blob(raw_signed_id: payload[:blob_signed_id])
      storage_key = resolve_storage_key!(blob: blob, payload_storage_key: payload[:storage_key])

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

    def resolve_storage_key!(blob:, payload_storage_key:)
      return payload_storage_key.to_s.strip if blob.blank?

      validate_blob_tenant_metadata!(blob: blob)
      provided_storage_key = payload_storage_key.to_s.strip
      if provided_storage_key.present? && provided_storage_key != blob.key
        raise_validation_error!("storage_key_blob_mismatch", "storage_key does not match blob key.")
      end

      provided_storage_key.presence || blob.key
    end

    def metadata_allowed_keys_credential_key
      :kyc_document_metadata_allowed_keys
    end

    def metadata_allowed_keys_env_var
      "KYC_DOCUMENT_METADATA_ALLOWED_KEYS"
    end

    def parse_date(raw_date, field:)
      return nil if raw_date.blank?

      Date.iso8601(raw_date.to_s)
    rescue ArgumentError
      raise_validation_error!("invalid_#{field}", "#{field} is invalid.")
    end

    def blob_actor_party_mismatch_message
      "blob metadata actor party does not match profile party."
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
      ensure_replay_outbox_operation!(existing_outbox)
      ensure_replay_payload_hash!(existing_outbox:, payload_hash:)

      kyc_document = find_replay_document(existing_outbox)
      create_action_log!(
        action_type: "KYC_DOCUMENT_REPLAYED",
        success: true,
        actor_party_id: kyc_document.party_id,
        target_id: kyc_document.id,
        metadata: { replayed: true, idempotency_key: @idempotency_key }
      )

      Result.new(kyc_document: kyc_document, replayed: true)
    end

    def find_replay_document(existing_outbox)
      kyc_document_id = existing_outbox.payload&.dig("kyc_document_id")
      raise_validation_error!("replay_document_not_found", "Replay document was not found.") if kyc_document_id.blank?

      KycDocument.where(tenant_id: @tenant_id).find(kyc_document_id)
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
        payload: outbox_payload(kyc_profile: kyc_profile, kyc_document: kyc_document, payload_hash: payload_hash)
      )
    end

    def outbox_payload(kyc_profile:, kyc_document:, payload_hash:)
      {
        PAYLOAD_HASH_KEY => payload_hash,
        "kyc_profile_id" => kyc_profile.id,
        "kyc_document_id" => kyc_document.id
      }
    end

    def create_action_log!(action_type:, success:, actor_party_id:, target_id:, metadata:)
      ActionIpLog.create!(
        **base_action_log_attributes(
          action_type: action_type,
          actor_party_id: actor_party_id,
          target_type: "KycDocument",
          target_id: target_id,
          success: success
        ),
        metadata: normalize_metadata(metadata)
      )
    end

    def create_failure_log(error:, target_id:, actor_party_id:)
      ActionIpLog.create!(
        **base_action_log_attributes(
          action_type: "KYC_DOCUMENT_SUBMIT_FAILED",
          actor_party_id: actor_party_id,
          target_type: TARGET_TYPE,
          target_id: target_id,
          success: false
        ),
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

    def base_action_log_attributes(action_type:, actor_party_id:, target_type:, target_id:, success:)
      {
        tenant_id: @tenant_id,
        actor_party_id: actor_party_id,
        action_type: action_type,
        ip_address: @request_ip.presence || "0.0.0.0",
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: "API",
        target_type: target_type,
        target_id: target_id,
        success: success,
        occurred_at: Time.current
      }
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
