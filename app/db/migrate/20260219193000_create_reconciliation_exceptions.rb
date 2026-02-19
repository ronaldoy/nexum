class CreateReconciliationExceptions < ActiveRecord::Migration[8.2]
  SOURCES = %w[ESCROW_WEBHOOK].freeze
  PROVIDERS = %w[QITECH STARKBANK].freeze
  STATUSES = %w[OPEN RESOLVED].freeze

  def up
    create_table :reconciliation_exceptions, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :resolved_by_party, type: :uuid, foreign_key: { to_table: :parties }
      t.string :source, null: false
      t.string :provider, null: false
      t.string :external_event_id, null: false
      t.string :code, null: false
      t.string :message, null: false
      t.string :payload_sha256
      t.jsonb :payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.string :status, null: false, default: "OPEN"
      t.integer :occurrences_count, null: false, default: 1
      t.datetime :first_seen_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :last_seen_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :resolved_at
      t.timestamps
    end

    add_check_constraint(
      :reconciliation_exceptions,
      "source IN ('#{SOURCES.join("','")}')",
      name: "reconciliation_exceptions_source_check"
    )
    add_check_constraint(
      :reconciliation_exceptions,
      "provider IN ('#{PROVIDERS.join("','")}')",
      name: "reconciliation_exceptions_provider_check"
    )
    add_check_constraint(
      :reconciliation_exceptions,
      "status IN ('#{STATUSES.join("','")}')",
      name: "reconciliation_exceptions_status_check"
    )
    add_check_constraint(
      :reconciliation_exceptions,
      "btrim(external_event_id) <> ''",
      name: "reconciliation_exceptions_external_event_id_present_check"
    )
    add_check_constraint(
      :reconciliation_exceptions,
      "btrim(code) <> ''",
      name: "reconciliation_exceptions_code_present_check"
    )
    add_check_constraint(
      :reconciliation_exceptions,
      "btrim(message) <> ''",
      name: "reconciliation_exceptions_message_present_check"
    )
    add_check_constraint(
      :reconciliation_exceptions,
      "occurrences_count > 0",
      name: "reconciliation_exceptions_occurrences_count_positive_check"
    )
    add_check_constraint(
      :reconciliation_exceptions,
      "payload_sha256 IS NULL OR payload_sha256 ~ '^[0-9a-f]{64}$'",
      name: "reconciliation_exceptions_payload_sha256_check"
    )

    add_index(
      :reconciliation_exceptions,
      %i[tenant_id source provider external_event_id code],
      unique: true,
      name: "index_reconciliation_exceptions_unique_signature"
    )
    add_index(
      :reconciliation_exceptions,
      %i[tenant_id status last_seen_at],
      name: "index_reconciliation_exceptions_open_lookup"
    )

    enable_tenant_rls("reconciliation_exceptions")
  end

  def down
    drop_table :reconciliation_exceptions
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
