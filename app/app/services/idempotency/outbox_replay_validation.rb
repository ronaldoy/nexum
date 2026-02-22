module Idempotency
  module OutboxReplayValidation
    private

    def ensure_replay_outbox_operation!(existing_outbox)
      return if existing_outbox.event_type == replay_outbox_event_type &&
        existing_outbox.aggregate_type == replay_target_type

      raise_idempotency_conflict!(
        code: "idempotency_key_reused_with_different_operation",
        message: idempotency_operation_conflict_message,
        existing_outbox: existing_outbox
      )
    end

    def ensure_replay_payload_hash!(existing_outbox:, payload_hash:)
      existing_payload_hash = existing_outbox.payload&.dig(replay_payload_hash_key).to_s
      if existing_payload_hash.blank?
        return if allow_blank_replay_payload_hash?(existing_outbox: existing_outbox)

        raise_idempotency_conflict!(
          code: "idempotency_key_reused_without_payload_hash",
          message: idempotency_missing_payload_hash_conflict_message,
          existing_outbox: existing_outbox
        )
      end
      return if existing_payload_hash == payload_hash.to_s

      raise_idempotency_conflict!(
        code: "idempotency_key_reused_with_different_payload",
        message: idempotency_payload_conflict_message,
        existing_outbox: existing_outbox
      )
    end

    def replay_outbox_event_type
      required_class_constant!(:OUTBOX_EVENT_TYPE)
    end

    def replay_target_type
      required_class_constant!(:TARGET_TYPE)
    end

    def replay_payload_hash_key
      required_class_constant!(:PAYLOAD_HASH_KEY)
    end

    def idempotency_operation_conflict_message
      "Idempotency-Key was already used with a different operation."
    end

    def idempotency_missing_payload_hash_conflict_message
      "Idempotency-Key replay is blocked because stored payload hash evidence is missing."
    end

    def idempotency_payload_conflict_message
      "Idempotency-Key was already used with a different payload."
    end

    def allow_blank_replay_payload_hash?(existing_outbox:)
      false
    end

    def raise_idempotency_conflict!(code:, message:, existing_outbox: nil)
      instrument_idempotency_conflict!(code: code, message: message, existing_outbox: existing_outbox)
      conflict_class = required_class_constant!(:IdempotencyConflict)
      raise conflict_class.new(code:, message:)
    end

    def instrument_idempotency_conflict!(code:, message:, existing_outbox:)
      payload = {
        code: code,
        message: message,
        service: self.class.name,
        tenant_id: @tenant_id,
        idempotency_key: @idempotency_key,
        request_id: @request_id,
        outbox_event_id: existing_outbox&.id
      }

      ActiveSupport::Notifications.instrument("idempotency.conflict", payload)
      Rails.logger.warn(
        "idempotency_conflict " \
          "service=#{payload[:service]} " \
          "code=#{payload[:code]} " \
          "tenant_id=#{payload[:tenant_id]} " \
          "idempotency_key=#{payload[:idempotency_key]} " \
          "request_id=#{payload[:request_id]} " \
          "outbox_event_id=#{payload[:outbox_event_id]}"
      )
    end

    def required_class_constant!(constant_name)
      return self.class.const_get(constant_name) if self.class.const_defined?(constant_name)

      raise NotImplementedError,
        "#{self.class.name} must define #{constant_name} to include Idempotency::OutboxReplayValidation."
    end
  end
end
