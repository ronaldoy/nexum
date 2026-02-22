require "digest"

module KycProfiles
  class Create
    include Idempotency::OutboxReplayValidation

    OUTBOX_EVENT_TYPE = "KYC_PROFILE_CREATED".freeze
    TARGET_TYPE = "KycProfile".freeze
    PAYLOAD_HASH_KEY = "payload_hash".freeze

    Result = Struct.new(:kyc_profile, :replayed, keyword_init: true) do
      def replayed?
        replayed
      end
    end
    CreateInputs = Struct.new(:party_id, :status, :risk_level, :metadata, :payload_hash, keyword_init: true)

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

    def call(raw_payload, default_party_id:)
      inputs = build_create_inputs(raw_payload:, default_party_id:)
      ActiveRecord::Base.transaction do
        create_or_replay(inputs)
      end
    rescue ValidationError => error
      failure_target_id = resolve_failure_target_id(inputs: inputs, raw_payload: raw_payload)
      create_failure_log(error: error, target_id: failure_target_id, actor_party_id: nil)
      raise
    rescue ActiveRecord::RecordInvalid => error
      validation_error = ValidationError.new(
        code: "invalid_kyc_profile",
        message: error.record.errors.full_messages.to_sentence
      )
      failure_target_id = resolve_failure_target_id(inputs: inputs, raw_payload: raw_payload)
      create_failure_log(error: validation_error, target_id: failure_target_id, actor_party_id: nil)
      raise validation_error
    rescue ActiveRecord::RecordNotFound => error
      failure_target_id = resolve_failure_target_id(inputs: inputs, raw_payload: raw_payload)
      create_failure_log(error: error, target_id: failure_target_id, actor_party_id: nil)
      raise
    rescue ActiveRecord::RecordNotUnique
      replay_after_unique_violation(payload_hash: inputs&.payload_hash.to_s)
    end

    private

    def resolve_failure_target_id(inputs:, raw_payload:)
      inputs&.party_id || raw_payload.to_h[:party_id]
    end

    def replay_after_unique_violation(payload_hash:)
      existing_outbox = OutboxEvent.find_by!(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      replay_result(existing_outbox:, payload_hash: payload_hash)
    end

    def build_create_inputs(raw_payload:, default_party_id:)
      payload = raw_payload.to_h.deep_symbolize_keys
      party_id = payload[:party_id].presence || default_party_id
      raise_validation_error!("party_required", "party_id is required.") if party_id.blank?

      status = normalize_status
      risk_level = normalize_risk_level
      metadata = normalize_metadata(payload[:metadata] || {})
      unless metadata.is_a?(Hash)
        raise_validation_error!("invalid_metadata", "metadata must be a JSON object.")
      end

      payload_hash = build_payload_hash(
        party_id: party_id,
        status: status,
        risk_level: risk_level,
        metadata: metadata
      )

      CreateInputs.new(
        party_id: party_id,
        status: status,
        risk_level: risk_level,
        metadata: metadata,
        payload_hash: payload_hash
      )
    end

    def create_or_replay(inputs)
      existing_outbox = OutboxEvent.lock.find_by(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      return replay_result(existing_outbox:, payload_hash: inputs.payload_hash) if existing_outbox

      create_new_profile_result!(inputs)
    end

    def create_new_profile_result!(inputs)
      party = Party.where(tenant_id: @tenant_id).lock.find(inputs.party_id)
      ensure_profile_absent!(party)

      kyc_profile = KycProfile.create!(
        tenant_id: @tenant_id,
        party: party,
        status: inputs.status,
        risk_level: inputs.risk_level,
        metadata: inputs.metadata
      )

      append_profile_artifacts!(kyc_profile:, party:, payload_hash: inputs.payload_hash)
      log_profile_creation_success!(kyc_profile:, party:)

      Result.new(kyc_profile:, replayed: false)
    end

    def ensure_profile_absent!(party)
      existing_profile = KycProfile.where(tenant_id: @tenant_id, party_id: party.id).lock.first
      return if existing_profile.blank?

      raise ValidationError.new(
        code: "kyc_profile_already_exists",
        message: "KYC profile already exists for this party."
      )
    end

    def append_profile_artifacts!(kyc_profile:, party:, payload_hash:)
      create_kyc_event!(
        kyc_profile: kyc_profile,
        party: party,
        event_type: OUTBOX_EVENT_TYPE,
        payload: profile_event_payload(kyc_profile)
      )

      create_outbox_event!(
        kyc_profile: kyc_profile,
        payload_hash: payload_hash
      )
    end

    def profile_event_payload(kyc_profile)
      {
        "idempotency_key" => @idempotency_key,
        "status" => kyc_profile.status,
        "risk_level" => kyc_profile.risk_level
      }
    end

    def log_profile_creation_success!(kyc_profile:, party:)
      create_action_log!(
        action_type: "KYC_PROFILE_CREATED",
        success: true,
        actor_party_id: party.id,
        target_id: kyc_profile.id,
        metadata: { replayed: false, idempotency_key: @idempotency_key }
      )
    end

    def normalize_status
      "DRAFT"
    end

    def normalize_risk_level
      "UNKNOWN"
    end

    def replay_result(existing_outbox:, payload_hash:)
      ensure_replay_outbox_operation!(existing_outbox)
      ensure_replay_payload_hash!(existing_outbox:, payload_hash:)

      kyc_profile = KycProfile.where(tenant_id: @tenant_id).find(existing_outbox.aggregate_id)
      create_action_log!(
        action_type: "KYC_PROFILE_REPLAYED",
        success: true,
        actor_party_id: kyc_profile.party_id,
        target_id: kyc_profile.id,
        metadata: { replayed: true, idempotency_key: @idempotency_key }
      )

      Result.new(kyc_profile: kyc_profile, replayed: true)
    end

    def create_kyc_event!(kyc_profile:, party:, event_type:, payload:)
      KycEvent.create!(
        tenant_id: @tenant_id,
        kyc_profile: kyc_profile,
        party: party,
        actor_party_id: Current.user&.party_id,
        event_type: event_type,
        occurred_at: Time.current,
        request_id: @request_id,
        payload: normalize_metadata(payload)
      )
    end

    def create_outbox_event!(kyc_profile:, payload_hash:)
      OutboxEvent.create!(
        tenant_id: @tenant_id,
        aggregate_type: TARGET_TYPE,
        aggregate_id: kyc_profile.id,
        event_type: OUTBOX_EVENT_TYPE,
        status: "PENDING",
        idempotency_key: @idempotency_key,
        payload: outbox_payload(kyc_profile: kyc_profile, payload_hash: payload_hash)
      )
    end

    def outbox_payload(kyc_profile:, payload_hash:)
      {
        PAYLOAD_HASH_KEY => payload_hash,
        "kyc_profile_id" => kyc_profile.id
      }
    end

    def create_action_log!(action_type:, success:, actor_party_id:, target_id:, metadata:)
      ActionIpLog.create!(
        **base_action_log_attributes(
          action_type: action_type,
          actor_party_id: actor_party_id,
          target_id: target_id,
          success: success
        ),
        metadata: normalize_metadata(metadata)
      )
    end

    def create_failure_log(error:, target_id:, actor_party_id:)
      ActionIpLog.create!(
        **base_action_log_attributes(
          action_type: "KYC_PROFILE_CREATE_FAILED",
          actor_party_id: actor_party_id,
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
        "kyc_profile_create_failure_log_write_error " \
        "error_class=#{log_error.class.name} error_message=#{log_error.message} " \
        "original_error_class=#{error.class.name} request_id=#{@request_id}"
      )
      nil
    end

    def base_action_log_attributes(action_type:, actor_party_id:, target_id:, success:)
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
        target_type: TARGET_TYPE,
        target_id: target_id,
        success: success,
        occurred_at: Time.current
      }
    end

    def build_payload_hash(party_id:, status:, risk_level:, metadata:)
      Digest::SHA256.hexdigest(
        canonical_json(
          party_id: party_id.to_s,
          status: status,
          risk_level: risk_level,
          metadata: metadata
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
