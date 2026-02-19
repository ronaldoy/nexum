class CreateProviderWebhookReceipts < ActiveRecord::Migration[8.2]
  PROVIDERS = %w[QITECH STARKBANK].freeze
  STATUSES = %w[PROCESSED IGNORED FAILED].freeze

  def up
    create_table :provider_webhook_receipts, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.string :provider, null: false
      t.string :provider_event_id, null: false
      t.string :event_type
      t.string :signature
      t.string :payload_sha256, null: false
      t.jsonb :payload, null: false, default: {}
      t.jsonb :request_headers, null: false, default: {}
      t.string :status, null: false
      t.string :error_code
      t.string :error_message
      t.datetime :processed_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end

    add_check_constraint(
      :provider_webhook_receipts,
      "provider IN ('#{PROVIDERS.join("','")}')",
      name: "provider_webhook_receipts_provider_check"
    )
    add_check_constraint(
      :provider_webhook_receipts,
      "status IN ('#{STATUSES.join("','")}')",
      name: "provider_webhook_receipts_status_check"
    )
    add_check_constraint(
      :provider_webhook_receipts,
      "btrim(provider_event_id) <> ''",
      name: "provider_webhook_receipts_event_id_present_check"
    )
    add_check_constraint(
      :provider_webhook_receipts,
      "payload_sha256 ~ '^[0-9a-f]{64}$'",
      name: "provider_webhook_receipts_payload_sha256_check"
    )

    add_index(
      :provider_webhook_receipts,
      %i[tenant_id provider provider_event_id],
      unique: true,
      name: "index_provider_webhook_receipts_unique_event"
    )
    add_index(
      :provider_webhook_receipts,
      %i[tenant_id provider status processed_at],
      name: "index_provider_webhook_receipts_lookup"
    )

    enable_tenant_rls("provider_webhook_receipts")
  end

  def down
    drop_table :provider_webhook_receipts
  end

  private

  def enable_tenant_rls(table_name)
    execute <<~SQL
      ALTER TABLE #{table_name} ENABLE ROW LEVEL SECURITY;
      ALTER TABLE #{table_name} FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS #{table_name}_tenant_policy ON #{table_name};
      CREATE POLICY #{table_name}_tenant_policy
      ON #{table_name}
      USING (tenant_id = app_current_tenant_id())
      WITH CHECK (tenant_id = app_current_tenant_id());
    SQL
  end
end
