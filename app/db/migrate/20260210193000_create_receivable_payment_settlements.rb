class CreateReceivablePaymentSettlements < ActiveRecord::Migration[8.2]
  APPEND_ONLY_TABLES = %w[
    receivable_payment_settlements
    anticipation_settlement_entries
  ].freeze

  def change
    create_table :receivable_payment_settlements, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :receivable, null: false, type: :uuid, foreign_key: true
      t.references :receivable_allocation, type: :uuid, foreign_key: true
      t.decimal :paid_amount, precision: 18, scale: 2, null: false
      t.decimal :cnpj_amount, precision: 18, scale: 2, null: false, default: 0
      t.decimal :fdic_amount, precision: 18, scale: 2, null: false, default: 0
      t.decimal :beneficiary_amount, precision: 18, scale: 2, null: false, default: 0
      t.decimal :fdic_balance_before, precision: 18, scale: 2, null: false, default: 0
      t.decimal :fdic_balance_after, precision: 18, scale: 2, null: false, default: 0
      t.datetime :paid_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.string :payment_reference
      t.string :request_id
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint :receivable_payment_settlements, "paid_amount > 0", name: "receivable_payment_settlements_paid_positive_check"
    add_check_constraint :receivable_payment_settlements, "cnpj_amount >= 0", name: "receivable_payment_settlements_cnpj_non_negative_check"
    add_check_constraint :receivable_payment_settlements, "fdic_amount >= 0", name: "receivable_payment_settlements_fdic_non_negative_check"
    add_check_constraint :receivable_payment_settlements, "beneficiary_amount >= 0", name: "receivable_payment_settlements_beneficiary_non_negative_check"
    add_check_constraint :receivable_payment_settlements, "fdic_balance_before >= 0", name: "receivable_payment_settlements_fdic_before_non_negative_check"
    add_check_constraint :receivable_payment_settlements, "fdic_balance_after >= 0", name: "receivable_payment_settlements_fdic_after_non_negative_check"
    add_check_constraint :receivable_payment_settlements, "fdic_balance_before >= fdic_balance_after", name: "receivable_payment_settlements_fdic_balance_flow_check"
    add_check_constraint :receivable_payment_settlements, "(cnpj_amount + fdic_amount + beneficiary_amount) = paid_amount", name: "receivable_payment_settlements_split_total_check"

    add_index :receivable_payment_settlements,
      %i[tenant_id receivable_id paid_at],
      name: "idx_rps_tenant_receivable_paid_at"
    add_index :receivable_payment_settlements,
      %i[tenant_id payment_reference],
      unique: true,
      where: "payment_reference IS NOT NULL",
      name: "idx_rps_tenant_payment_ref"

    create_table :anticipation_settlement_entries, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :receivable_payment_settlement, null: false, type: :uuid, foreign_key: true
      t.references :anticipation_request, null: false, type: :uuid, foreign_key: true
      t.decimal :settled_amount, precision: 18, scale: 2, null: false
      t.datetime :settled_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint :anticipation_settlement_entries, "settled_amount > 0", name: "anticipation_settlement_entries_settled_positive_check"
    add_index :anticipation_settlement_entries,
      %i[tenant_id anticipation_request_id settled_at],
      name: "idx_ase_tenant_request_settled_at"
    add_index :anticipation_settlement_entries,
      %i[receivable_payment_settlement_id anticipation_request_id],
      unique: true,
      name: "idx_ase_unique_request_per_payment"

    APPEND_ONLY_TABLES.each { |table_name| create_append_only_triggers(table_name) }
    APPEND_ONLY_TABLES.each { |table_name| enable_tenant_rls(table_name) }
  end

  private

  def create_append_only_triggers(table_name)
    execute <<~SQL
      DROP TRIGGER IF EXISTS #{table_name}_no_update_delete ON #{table_name};
      CREATE TRIGGER #{table_name}_no_update_delete
      BEFORE UPDATE OR DELETE ON #{table_name}
      FOR EACH ROW
      EXECUTE FUNCTION app_forbid_mutation();
    SQL
  end

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
