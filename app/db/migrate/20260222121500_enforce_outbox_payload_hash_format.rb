class EnforceOutboxPayloadHashFormat < ActiveRecord::Migration[8.2]
  PAYLOAD_HASH_FORMAT_CONSTRAINT = "outbox_events_idempotency_payload_hash_format_check".freeze
  PAYLOAD_HASH_ROLLOUT_CUTOFF_UTC = "2026-02-22 00:00:00+00".freeze

  def up
    add_check_constraint :outbox_events,
      payload_hash_format_check_expression,
      name: PAYLOAD_HASH_FORMAT_CONSTRAINT
  end

  def down
    remove_check_constraint :outbox_events, name: PAYLOAD_HASH_FORMAT_CONSTRAINT
  end

  private

  def payload_hash_format_check_expression
    <<~SQL.squish
      idempotency_key IS NULL
      OR created_at < TIMESTAMPTZ '#{PAYLOAD_HASH_ROLLOUT_CUTOFF_UTC}'
      OR (payload ->> 'payload_hash') ~ '^[0-9a-f]{64}$'
    SQL
  end
end
