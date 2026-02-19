class CreateFdicOperations < ActiveRecord::Migration[8.2]
  PROVIDERS = %w[MOCK WEBHOOK].freeze
  OPERATION_TYPES = %w[FUNDING_REQUEST SETTLEMENT_REPORT].freeze
  STATUSES = %w[PENDING SENT FAILED].freeze

  def up
    create_table :fdic_operations, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :anticipation_request, type: :uuid, foreign_key: true
      t.references :receivable_payment_settlement, type: :uuid, foreign_key: true
      t.string :provider, null: false
      t.string :operation_type, null: false
      t.string :status, null: false, default: "PENDING"
      t.decimal :amount, precision: 18, scale: 2, null: false
      t.string :currency, null: false, default: "BRL"
      t.string :idempotency_key, null: false
      t.string :provider_reference
      t.datetime :requested_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :processed_at
      t.string :last_error_code
      t.string :last_error_message
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :fdic_operations,
      "provider IN ('#{PROVIDERS.join("','")}')",
      name: "fdic_operations_provider_check"
    )
    add_check_constraint(
      :fdic_operations,
      "operation_type IN ('#{OPERATION_TYPES.join("','")}')",
      name: "fdic_operations_operation_type_check"
    )
    add_check_constraint(
      :fdic_operations,
      "status IN ('#{STATUSES.join("','")}')",
      name: "fdic_operations_status_check"
    )
    add_check_constraint(
      :fdic_operations,
      "amount > 0",
      name: "fdic_operations_amount_positive_check"
    )
    add_check_constraint(
      :fdic_operations,
      "currency = 'BRL'",
      name: "fdic_operations_currency_check"
    )
    add_check_constraint(
      :fdic_operations,
      "btrim(idempotency_key) <> ''",
      name: "fdic_operations_idempotency_key_present_check"
    )
    add_check_constraint(
      :fdic_operations,
      "((anticipation_request_id IS NOT NULL) AND (receivable_payment_settlement_id IS NULL)) OR ((anticipation_request_id IS NULL) AND (receivable_payment_settlement_id IS NOT NULL))",
      name: "fdic_operations_single_source_reference_check"
    )

    add_index(
      :fdic_operations,
      %i[tenant_id idempotency_key],
      unique: true,
      name: "index_fdic_operations_on_tenant_idempotency_key"
    )
    add_index(
      :fdic_operations,
      %i[tenant_id operation_type status requested_at],
      name: "index_fdic_operations_dispatch_scan"
    )
    add_index(
      :fdic_operations,
      %i[tenant_id anticipation_request_id operation_type],
      unique: true,
      where: "anticipation_request_id IS NOT NULL",
      name: "index_fdic_operations_unique_funding_per_request"
    )
    add_index(
      :fdic_operations,
      %i[tenant_id receivable_payment_settlement_id operation_type],
      unique: true,
      where: "receivable_payment_settlement_id IS NOT NULL",
      name: "index_fdic_operations_unique_settlement_per_payment"
    )

    enable_tenant_rls("fdic_operations")
  end

  def down
    drop_table :fdic_operations
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
