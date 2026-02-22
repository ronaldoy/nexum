module Idempotency
  module OutboxReplayValidation
    private

    def ensure_replay_outbox_operation!(existing_outbox)
      return if existing_outbox.event_type == replay_outbox_event_type &&
        existing_outbox.aggregate_type == replay_target_type

      raise_idempotency_conflict!(
        code: "idempotency_key_reused_with_different_operation",
        message: idempotency_operation_conflict_message
      )
    end

    def ensure_replay_payload_hash!(existing_outbox:, payload_hash:)
      existing_payload_hash = existing_outbox.payload&.dig(replay_payload_hash_key).to_s
      return if existing_payload_hash.blank? || existing_payload_hash == payload_hash.to_s

      raise_idempotency_conflict!(
        code: "idempotency_key_reused_with_different_payload",
        message: idempotency_payload_conflict_message
      )
    end

    def replay_outbox_event_type
      self.class::OUTBOX_EVENT_TYPE
    end

    def replay_target_type
      self.class::TARGET_TYPE
    end

    def replay_payload_hash_key
      self.class::PAYLOAD_HASH_KEY
    end

    def idempotency_operation_conflict_message
      "Idempotency-Key was already used with a different operation."
    end

    def idempotency_payload_conflict_message
      "Idempotency-Key was already used with a different payload."
    end

    def raise_idempotency_conflict!(code:, message:)
      raise self.class::IdempotencyConflict.new(code:, message:)
    end
  end
end
