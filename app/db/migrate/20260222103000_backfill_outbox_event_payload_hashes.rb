class BackfillOutboxEventPayloadHashes < ActiveRecord::Migration[8.2]
  APPEND_ONLY_TRIGGER = "outbox_events_no_update_delete".freeze
  PAYLOAD_HASH_CONSTRAINT = "outbox_events_idempotency_payload_hash_present_check".freeze
  PAYLOAD_HASH_ROLLOUT_CUTOFF_UTC = "2026-02-22 00:00:00+00".freeze

  def up
    backfill_missing_idempotency_payload_hashes!

    add_check_constraint :outbox_events,
      payload_hash_check_expression,
      name: PAYLOAD_HASH_CONSTRAINT
  end

  def down
    remove_check_constraint :outbox_events, name: PAYLOAD_HASH_CONSTRAINT
  end

  private

  def payload_hash_check_expression
    <<~SQL.squish
      idempotency_key IS NULL
      OR created_at < TIMESTAMPTZ '#{PAYLOAD_HASH_ROLLOUT_CUTOFF_UTC}'
      OR NULLIF(BTRIM(payload ->> 'payload_hash'), '') IS NOT NULL
    SQL
  end

  def backfill_missing_idempotency_payload_hashes!
    with_outbox_append_only_trigger_disabled do
      execute <<~SQL
        UPDATE outbox_events
        SET payload = jsonb_set(
          COALESCE(payload, '{}'::jsonb),
          '{payload_hash}',
          to_jsonb(
            encode(
              digest((COALESCE(payload, '{}'::jsonb) - 'payload_hash')::text, 'sha256'),
              'hex'
            )::text
          ),
          true
        )
        WHERE idempotency_key IS NOT NULL
          AND COALESCE(NULLIF(BTRIM(payload ->> 'payload_hash'), ''), '') = '';
      SQL
    end
  end

  def with_outbox_append_only_trigger_disabled
    execute "ALTER TABLE outbox_events DISABLE TRIGGER #{APPEND_ONLY_TRIGGER};"
    yield
  ensure
    execute "ALTER TABLE outbox_events ENABLE TRIGGER #{APPEND_ONLY_TRIGGER};"
  end
end
