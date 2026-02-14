require "digest"

module Receivables
  class AttachSignedDocument
    OUTBOX_EVENT_TYPE = "RECEIVABLE_DOCUMENT_ATTACHED".freeze
    TARGET_TYPE = "Receivable".freeze
    PAYLOAD_HASH_KEY = "payload_hash".freeze
    EVENT_TYPE = "RECEIVABLE_DOCUMENT_ATTACHED".freeze
    DOCUMENT_EVENT_TYPE = "DOCUMENT_SIGNED_METADATA_ATTACHED".freeze
    REQUIRED_SIGNATURE_METHOD = "OWN_PLATFORM_CONFIRMATION".freeze
    SIGNATURE_CONFIRMATION_PURPOSE = "DOCUMENT_SIGNATURE_CONFIRMATION".freeze

    Result = Struct.new(:document, :replayed, keyword_init: true) do
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

    def call(receivable_id:, raw_payload:, default_actor_party_id:, privileged_actor: false)
      payload = normalize_payload(
        raw_payload.to_h,
        default_actor_party_id: default_actor_party_id,
        privileged_actor: privileged_actor
      )
      payload_hash = build_payload_hash(receivable_id:, payload:)

      result = nil
      failure = nil

      ActiveRecord::Base.transaction do
        existing_outbox = OutboxEvent.lock.find_by(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
        if existing_outbox
          begin
            result = replay_result(existing_outbox:, payload_hash:)
          rescue ValidationError => error
            failure = error
          end
          next
        end

        receivable = Receivable.where(tenant_id: @tenant_id).lock.find(receivable_id)
        actor_party = resolve_actor_party!(payload.fetch(:actor_party_id))
        ensure_actor_party_authorized!(receivable:, actor_party:)
        ensure_verified_challenge_pair!(
          receivable: receivable,
          actor_party: actor_party,
          email_challenge_id: payload.fetch(:email_challenge_id),
          whatsapp_challenge_id: payload.fetch(:whatsapp_challenge_id)
        )

        document = Document.create!(
          tenant_id: @tenant_id,
          receivable: receivable,
          actor_party: actor_party,
          document_type: payload.fetch(:document_type),
          signature_method: payload.fetch(:signature_method),
          status: "SIGNED",
          sha256: payload.fetch(:sha256),
          storage_key: payload.fetch(:storage_key),
          signed_at: payload.fetch(:signed_at),
          metadata: payload.fetch(:metadata)
        )
        attach_blob!(record: document, blob: payload[:blob])

        create_document_event!(
          document:,
          receivable:,
          actor_party:,
          payload:
        )
        create_receivable_event!(
          receivable:,
          document:,
          actor_party:,
          payload:
        )
        create_outbox_event!(
          receivable:,
          document:,
          payload_hash:
        )
        create_action_log!(
          action_type: "RECEIVABLE_DOCUMENT_ATTACHED",
          success: true,
          actor_party_id: actor_party.id,
          target_id: document.id,
          metadata: {
            replayed: false,
            idempotency_key: @idempotency_key,
            receivable_id: receivable.id
          }
        )

        result = Result.new(document:, replayed: false)
      end

      if failure
        create_failure_log(error: failure, receivable_id: receivable_id)
        raise failure
      end

      result
    rescue ValidationError => error
      create_failure_log(error: error, receivable_id: receivable_id)
      raise
    rescue ActiveRecord::RecordInvalid => error
      validation_error = ValidationError.new(
        code: "invalid_document",
        message: error.record.errors.full_messages.to_sentence
      )
      create_failure_log(error: validation_error, receivable_id: receivable_id)
      raise validation_error
    rescue ActiveRecord::RecordNotFound => error
      create_failure_log(error: error, receivable_id: receivable_id)
      raise
    rescue ActiveRecord::RecordNotUnique => error
      existing_outbox = OutboxEvent.find_by(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      return replay_result(existing_outbox:, payload_hash:) if existing_outbox.present?

      if error.message.include?("index_documents_on_tenant_id_and_sha256")
        validation_error = ValidationError.new(
          code: "duplicate_document_hash",
          message: "A signed document with this sha256 already exists for this tenant."
        )
        create_failure_log(error: validation_error, receivable_id: receivable_id)
        raise validation_error
      end

      raise
    end

    private

    def normalize_payload(raw_payload, default_actor_party_id:, privileged_actor:)
      payload = raw_payload.deep_symbolize_keys
      metadata = normalize_metadata(payload[:metadata] || {})

      unless metadata.is_a?(Hash)
        raise_validation_error!("invalid_metadata", "metadata must be a JSON object.")
      end

      actor_party_id = payload[:actor_party_id].presence || default_actor_party_id
      raise_validation_error!("actor_party_required", "actor_party_id is required.") if actor_party_id.blank?
      if !privileged_actor && default_actor_party_id.to_s != actor_party_id.to_s
        raise_validation_error!("actor_party_mismatch", "actor_party_id must match authenticated actor.")
      end

      document_type = payload[:document_type].to_s.strip
      raise_validation_error!("document_type_required", "document_type is required.") if document_type.blank?

      sha256 = payload[:sha256].to_s.strip
      blob = resolve_blob(raw_signed_id: payload[:blob_signed_id])
      storage_key = payload[:storage_key].to_s.strip
      storage_key = blob.key if storage_key.blank? && blob.present?
      provider_envelope_id = payload[:provider_envelope_id].to_s.strip
      email_challenge_id = payload[:email_challenge_id].to_s.strip
      whatsapp_challenge_id = payload[:whatsapp_challenge_id].to_s.strip

      raise_validation_error!("sha256_required", "sha256 is required.") if sha256.blank?
      raise_validation_error!("storage_key_required", "storage_key is required.") if storage_key.blank?
      if blob.present? && payload[:storage_key].to_s.strip.present? && payload[:storage_key].to_s.strip != blob.key
        raise_validation_error!("storage_key_blob_mismatch", "storage_key does not match blob key.")
      end
      validate_blob_sha256!(blob:, expected_sha256: sha256) if blob.present?
      validate_blob_tenant_metadata!(blob:) if blob.present?
      raise_validation_error!("provider_envelope_id_required", "provider_envelope_id is required.") if provider_envelope_id.blank?
      raise_validation_error!("email_challenge_id_required", "email_challenge_id is required.") if email_challenge_id.blank?
      raise_validation_error!("whatsapp_challenge_id_required", "whatsapp_challenge_id is required.") if whatsapp_challenge_id.blank?

      signature_method = payload[:signature_method].presence || REQUIRED_SIGNATURE_METHOD
      normalized_signature_method = signature_method.to_s.upcase
      unless normalized_signature_method == REQUIRED_SIGNATURE_METHOD
        raise_validation_error!(
          "invalid_signature_method",
          "signature_method must be #{REQUIRED_SIGNATURE_METHOD}."
        )
      end

      signed_at = parse_time(payload[:signed_at], field: "signed_at")

      {
        actor_party_id: actor_party_id.to_s,
        document_type: document_type.upcase,
        signature_method: normalized_signature_method,
        sha256: sha256,
        storage_key: storage_key,
        blob: blob,
        signed_at: signed_at,
        provider_envelope_id: provider_envelope_id,
        email_challenge_id: email_challenge_id,
        whatsapp_challenge_id: whatsapp_challenge_id,
        metadata: metadata.merge(
          "provider_envelope_id" => provider_envelope_id,
          "email_challenge_id" => email_challenge_id,
          "whatsapp_challenge_id" => whatsapp_challenge_id,
          "idempotency_key" => @idempotency_key
        )
      }
    end

    def parse_time(raw_value, field:)
      case raw_value
      when ActiveSupport::TimeWithZone, Time
        raw_value
      when DateTime
        raw_value.to_time
      else
        value = raw_value.to_s.strip
        raise_validation_error!("invalid_#{field}", "#{field} is invalid.") if value.blank?

        Time.iso8601(value)
      end
    rescue ArgumentError, TypeError
      raise_validation_error!("invalid_#{field}", "#{field} is invalid.")
    end

    def resolve_blob(raw_signed_id:)
      signed_id = raw_signed_id.to_s.strip
      return nil if signed_id.blank?

      ActiveStorage::Blob.find_signed!(signed_id)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      raise_validation_error!("invalid_blob_signed_id", "blob_signed_id is invalid.")
    end

    def validate_blob_sha256!(blob:, expected_sha256:)
      actual = Digest::SHA256.hexdigest(blob.download)
      return if expected_sha256.bytesize == actual.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(actual, expected_sha256)

      raise_validation_error!("sha256_mismatch", "sha256 does not match uploaded content.")
    end

    def validate_blob_tenant_metadata!(blob:)
      metadata_tenant_id = blob.metadata&.dig("tenant_id")
      return if metadata_tenant_id.blank?
      return if metadata_tenant_id.to_s == @tenant_id.to_s

      raise_validation_error!("blob_tenant_mismatch", "blob metadata tenant does not match request tenant.")
    end

    def attach_blob!(record:, blob:)
      return if blob.blank?

      record.file.attach(blob)
    end

    def resolve_actor_party!(actor_party_id)
      Party.where(tenant_id: @tenant_id).find(actor_party_id)
    end

    def ensure_actor_party_authorized!(receivable:, actor_party:)
      allocation_scope = ReceivableAllocation.where(tenant_id: @tenant_id, receivable_id: receivable.id)
      allowed_party_ids = [
        receivable.debtor_party_id,
        receivable.creditor_party_id,
        receivable.beneficiary_party_id
      ] + allocation_scope.pluck(:allocated_party_id, :physician_party_id).flatten

      return if allowed_party_ids.compact.uniq.include?(actor_party.id)

      raise_validation_error!(
        "actor_party_not_authorized",
        "actor_party_id is not authorized for this receivable."
      )
    end

    def ensure_verified_challenge_pair!(receivable:, actor_party:, email_challenge_id:, whatsapp_challenge_id:)
      verify_signature_challenge!(
        challenge_id: email_challenge_id,
        channel: "EMAIL",
        receivable: receivable,
        actor_party: actor_party
      )
      verify_signature_challenge!(
        challenge_id: whatsapp_challenge_id,
        channel: "WHATSAPP",
        receivable: receivable,
        actor_party: actor_party
      )
    end

    def verify_signature_challenge!(challenge_id:, channel:, receivable:, actor_party:)
      challenge = AuthChallenge.where(tenant_id: @tenant_id).lock.find(challenge_id)
      unless challenge.delivery_channel == channel
        raise_validation_error!("invalid_#{channel.downcase}_challenge", "#{channel.downcase} challenge is invalid.")
      end
      unless challenge.status == "VERIFIED"
        raise_validation_error!("unverified_#{channel.downcase}_challenge", "#{channel.downcase} challenge must be verified.")
      end
      unless challenge.purpose == SIGNATURE_CONFIRMATION_PURPOSE
        raise_validation_error!("invalid_#{channel.downcase}_challenge_purpose", "#{channel.downcase} challenge purpose is invalid.")
      end
      unless challenge.target_type == TARGET_TYPE && challenge.target_id.to_s == receivable.id.to_s
        raise_validation_error!("invalid_#{channel.downcase}_challenge_target", "#{channel.downcase} challenge target is invalid.")
      end
      unless challenge.actor_party_id.to_s == actor_party.id.to_s
        raise_validation_error!("invalid_#{channel.downcase}_challenge_actor", "#{channel.downcase} challenge actor is invalid.")
      end
      return if challenge.expires_at > Time.current

      challenge.update!(status: "EXPIRED")
      raise_validation_error!("expired_#{channel.downcase}_challenge", "#{channel.downcase} challenge is expired.")
    rescue ActiveRecord::RecordNotFound
      raise_validation_error!("missing_#{channel.downcase}_challenge", "Missing #{channel.downcase} challenge.")
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

      document_id = existing_outbox.payload&.dig("document_id")
      raise_validation_error!("replay_document_not_found", "Replay document was not found.") if document_id.blank?

      document = Document.where(tenant_id: @tenant_id).find(document_id)
      create_action_log!(
        action_type: "RECEIVABLE_DOCUMENT_REPLAYED",
        success: true,
        actor_party_id: document.actor_party_id,
        target_id: document.id,
        metadata: { replayed: true, idempotency_key: @idempotency_key }
      )

      Result.new(document:, replayed: true)
    end

    def create_document_event!(document:, receivable:, actor_party:, payload:)
      DocumentEvent.create!(
        tenant_id: @tenant_id,
        document: document,
        receivable: receivable,
        actor_party: actor_party,
        event_type: DOCUMENT_EVENT_TYPE,
        occurred_at: payload.fetch(:signed_at),
        request_id: @request_id,
        payload: {
          "idempotency_key" => @idempotency_key,
          "signature_method" => payload.fetch(:signature_method),
          "provider_envelope_id" => payload.fetch(:provider_envelope_id),
          "email_challenge_id" => payload.fetch(:email_challenge_id),
          "whatsapp_challenge_id" => payload.fetch(:whatsapp_challenge_id)
        }
      )
    end

    def create_receivable_event!(receivable:, document:, actor_party:, payload:)
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous.fetch(0) + 1 : 1
      prev_hash = previous&.fetch(1)

      event_payload = {
        document_id: document.id,
        document_type: document.document_type,
        signature_method: payload.fetch(:signature_method),
        signed_at: payload.fetch(:signed_at).utc.iso8601(6),
        sha256: document.sha256,
        storage_key: document.storage_key,
        provider_envelope_id: payload.fetch(:provider_envelope_id),
        email_challenge_id: payload.fetch(:email_challenge_id),
        whatsapp_challenge_id: payload.fetch(:whatsapp_challenge_id)
      }

      event_hash = Digest::SHA256.hexdigest(
        canonical_json(
          receivable_id: receivable.id,
          sequence: sequence,
          event_type: EVENT_TYPE,
          occurred_at: payload.fetch(:signed_at).utc.iso8601(6),
          request_id: @request_id,
          prev_hash: prev_hash,
          payload: event_payload
        )
      )

      ReceivableEvent.create!(
        tenant_id: @tenant_id,
        receivable: receivable,
        sequence: sequence,
        event_type: EVENT_TYPE,
        actor_party: actor_party,
        actor_role: @actor_role,
        occurred_at: payload.fetch(:signed_at),
        request_id: @request_id,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: event_payload
      )
    end

    def create_outbox_event!(receivable:, document:, payload_hash:)
      OutboxEvent.create!(
        tenant_id: @tenant_id,
        aggregate_type: TARGET_TYPE,
        aggregate_id: receivable.id,
        event_type: OUTBOX_EVENT_TYPE,
        status: "PENDING",
        idempotency_key: @idempotency_key,
        payload: {
          PAYLOAD_HASH_KEY => payload_hash,
          "receivable_id" => receivable.id,
          "document_id" => document.id
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
        target_type: "Document",
        target_id: target_id,
        success: success,
        occurred_at: Time.current,
        metadata: normalize_metadata(metadata)
      )
    end

    def create_failure_log(error:, receivable_id:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        action_type: "RECEIVABLE_DOCUMENT_ATTACH_FAILED",
        ip_address: @request_ip.presence || "0.0.0.0",
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: "API",
        target_type: "Receivable",
        target_id: receivable_id,
        success: false,
        occurred_at: Time.current,
        metadata: {
          "idempotency_key" => @idempotency_key,
          "error_class" => error.class.name,
          "error_code" => error.respond_to?(:code) ? error.code : "not_found",
          "error_message" => error.message
        }
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      nil
    end

    def build_payload_hash(receivable_id:, payload:)
      Digest::SHA256.hexdigest(
        canonical_json(
          receivable_id: receivable_id.to_s,
          actor_party_id: payload.fetch(:actor_party_id),
          document_type: payload.fetch(:document_type),
          signature_method: payload.fetch(:signature_method),
          sha256: payload.fetch(:sha256),
          storage_key: payload.fetch(:storage_key),
          signed_at: payload.fetch(:signed_at).utc.iso8601(6),
          provider_envelope_id: payload.fetch(:provider_envelope_id),
          email_challenge_id: payload.fetch(:email_challenge_id),
          whatsapp_challenge_id: payload.fetch(:whatsapp_challenge_id),
          metadata: payload.fetch(:metadata)
        )
      )
    end

    def canonical_json(value)
      case value
      when Hash
        "{" + value.sort_by { |key, _| key.to_s }.map { |key, entry| "#{key.to_s.to_json}:#{canonical_json(entry)}" }.join(",") + "}"
      when Array
        "[" + value.map { |entry| canonical_json(entry) }.join(",") + "]"
      else
        value.to_json
      end
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
