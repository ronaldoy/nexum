require "digest"

module Physicians
  class Create
    TARGET_TYPE = "Physician".freeze
    PAYLOAD_HASH_METADATA_KEY = "_create_payload_hash".freeze

    Result = Struct.new(:physician, :party, :replayed, keyword_init: true) do
      def replayed?
        replayed
      end
    end
    CallInputs = Struct.new(:payload, :payload_hash, keyword_init: true)

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
      @idempotency_key = idempotency_key.to_s.strip
      @request_ip = request_ip
      @user_agent = user_agent
      @endpoint_path = endpoint_path
      @http_method = http_method
    end

    def call(raw_payload)
      raise_validation_error!("missing_idempotency_key", "Idempotency-Key is required.") if @idempotency_key.blank?

      inputs = build_call_inputs(raw_payload)
      ActiveRecord::Base.transaction { create_or_replay(inputs) }
    rescue ActiveRecord::RecordNotUnique
      replay_after_race(payload: inputs&.payload || normalize_payload(raw_payload), payload_hash: inputs&.payload_hash.to_s)
    rescue ActiveRecord::RecordInvalid => error
      raise ValidationError.new(code: "invalid_physician_payload", message: error.record.errors.full_messages.to_sentence)
    end

    private

    def build_call_inputs(raw_payload)
      payload = normalize_payload(raw_payload)
      payload_hash = physician_payload_hash(payload)
      CallInputs.new(payload:, payload_hash:)
    end

    def create_or_replay(inputs)
      existing_party = find_existing_party(inputs.payload)
      return replay_existing_party(existing_party:, inputs:) if existing_party

      create_new_physician(inputs)
    end

    def find_existing_party(payload)
      existing_party = Party.where(
        tenant_id: @tenant_id,
        kind: "PHYSICIAN_PF",
        document_number: payload.fetch(:document_number)
      ).lock.first
      return existing_party if existing_party
      return nil if payload[:external_ref].blank?

      Party.where(
        tenant_id: @tenant_id,
        kind: "PHYSICIAN_PF",
        external_ref: payload[:external_ref]
      ).lock.first
    end

    def replay_existing_party(existing_party:, inputs:)
      physician = Physician.where(tenant_id: @tenant_id, party_id: existing_party.id).lock.first
      if physician.blank?
        raise_validation_error!("physician_profile_missing", "Physician profile is missing for existing party.")
      end

      ensure_matching_replay!(physician: physician, payload_hash: inputs.payload_hash, payload: inputs.payload)
      create_action_log!(
        action_type: "PHYSICIAN_CREATE_REPLAYED",
        success: true,
        target_id: physician.id,
        metadata: { replayed: true, idempotency_key: @idempotency_key }
      )
      Result.new(physician: physician, party: existing_party, replayed: true)
    end

    def create_new_physician(inputs)
      party = create_physician_party!(inputs)
      physician = create_physician_profile!(inputs, party)
      create_action_log!(
        action_type: "PHYSICIAN_CREATED",
        success: true,
        target_id: physician.id,
        metadata: {
          replayed: false,
          idempotency_key: @idempotency_key,
          party_id: party.id,
          document_number: inputs.payload.fetch(:document_number)
        }
      )

      Result.new(physician: physician, party: party, replayed: false)
    end

    def create_physician_party!(inputs)
      payload = inputs.payload
      Party.create!(
        tenant_id: @tenant_id,
        kind: "PHYSICIAN_PF",
        external_ref: payload[:external_ref],
        legal_name: payload.fetch(:full_name),
        display_name: payload[:display_name].presence || payload.fetch(:full_name),
        document_type: "CPF",
        document_number: payload.fetch(:document_number),
        metadata: normalize_hash_metadata(payload[:party_metadata]).merge(
          PAYLOAD_HASH_METADATA_KEY => inputs.payload_hash,
          "idempotency_key" => @idempotency_key
        )
      )
    end

    def create_physician_profile!(inputs, party)
      payload = inputs.payload
      Physician.create!(
        tenant_id: @tenant_id,
        party: party,
        full_name: payload.fetch(:full_name),
        email: payload.fetch(:email),
        phone: payload[:phone],
        crm_number: payload[:crm_number],
        crm_state: payload[:crm_state],
        active: true,
        metadata: normalize_hash_metadata(payload[:metadata]).merge(
          PAYLOAD_HASH_METADATA_KEY => inputs.payload_hash,
          "idempotency_key" => @idempotency_key
        )
      )
    end

    def normalize_payload(raw_payload)
      payload = raw_payload.to_h.symbolize_keys
      full_name = payload[:full_name].to_s.strip
      email = payload[:email].to_s.strip.downcase
      document_number = payload[:document_number].to_s.gsub(/\D+/, "")
      crm_number = payload[:crm_number].to_s.gsub(/\D+/, "").presence
      crm_state = payload[:crm_state].to_s.strip.upcase.presence

      raise_validation_error!("full_name_required", "full_name is required.") if full_name.blank?
      raise_validation_error!("email_required", "email is required.") if email.blank?
      raise_validation_error!("document_number_required", "document_number is required.") if document_number.blank?

      {
        full_name: full_name,
        display_name: payload[:display_name].to_s.strip.presence,
        email: email,
        phone: payload[:phone].to_s.strip.presence,
        document_number: document_number,
        external_ref: payload[:external_ref].to_s.strip.presence,
        crm_number: crm_number,
        crm_state: crm_state,
        metadata: normalize_metadata(payload[:metadata]),
        party_metadata: normalize_metadata(payload[:party_metadata])
      }
    end

    def ensure_matching_replay!(physician:, payload_hash:, payload:)
      stored_hash = physician.metadata&.[](PAYLOAD_HASH_METADATA_KEY).to_s
      return if stored_hash.present? && stored_hash == payload_hash
      return if stored_hash.blank? && fallback_payload_match?(physician: physician, payload: payload)

      raise IdempotencyConflict.new(
        code: "idempotency_key_reused_with_different_payload",
        message: "Idempotency-Key was already used with a different physician payload."
      )
    end

    def fallback_payload_match?(physician:, payload:)
      physician_party = physician.party
      return false if physician_party.blank?

      physician.full_name == payload.fetch(:full_name) &&
        physician.email.to_s.downcase == payload.fetch(:email) &&
        physician.phone.to_s == payload[:phone].to_s &&
        physician_party.document_number.to_s == payload.fetch(:document_number) &&
        physician_party.external_ref.to_s == payload[:external_ref].to_s &&
        physician.crm_number.to_s == payload[:crm_number].to_s &&
        physician.crm_state.to_s == payload[:crm_state].to_s
    end

    def replay_after_race(payload:, payload_hash:)
      party = Party.find_by!(
        tenant_id: @tenant_id,
        kind: "PHYSICIAN_PF",
        document_number: payload.fetch(:document_number)
      )
      physician = Physician.find_by!(tenant_id: @tenant_id, party_id: party.id)
      ensure_matching_replay!(physician: physician, payload_hash: payload_hash, payload: payload)
      Result.new(physician: physician, party: party, replayed: true)
    end

    def physician_payload_hash(payload)
      Digest::SHA256.hexdigest(
        CanonicalJson.encode(
          full_name: payload.fetch(:full_name),
          display_name: payload[:display_name],
          email: payload.fetch(:email),
          phone: payload[:phone],
          document_number: payload.fetch(:document_number),
          external_ref: payload[:external_ref],
          crm_number: payload[:crm_number],
          crm_state: payload[:crm_state],
          metadata: payload[:metadata],
          party_metadata: payload[:party_metadata]
        )
      )
    end

    def create_action_log!(action_type:, success:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        actor_party_id: nil,
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
        metadata: normalize_metadata(metadata)
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => log_error
      Rails.logger.error(
        "physician_create_action_log_write_error " \
        "error_class=#{log_error.class.name} error_message=#{log_error.message} request_id=#{@request_id}"
      )
      nil
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

    def normalize_hash_metadata(raw_metadata)
      normalized = normalize_metadata(raw_metadata)
      normalized.is_a?(Hash) ? normalized : {}
    end

    def raise_validation_error!(code, message)
      raise ValidationError.new(code:, message:)
    end
  end
end
