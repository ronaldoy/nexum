class CreateAnticipationRiskRules < ActiveRecord::Migration[8.2]
  def up
    create_table :anticipation_risk_rules, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :scope_party, type: :uuid, foreign_key: { to_table: :parties }
      t.string :scope_type, null: false
      t.string :decision, null: false, default: "BLOCK"
      t.boolean :active, null: false, default: true
      t.integer :priority, null: false, default: 100
      t.decimal :max_single_request_amount, precision: 18, scale: 2
      t.decimal :max_daily_requested_amount, precision: 18, scale: 2
      t.decimal :max_outstanding_exposure_amount, precision: 18, scale: 2
      t.integer :max_open_requests_count
      t.datetime :effective_from
      t.datetime :effective_until
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :anticipation_risk_rules,
      "scope_type IN ('TENANT_DEFAULT', 'PHYSICIAN_PARTY', 'CNPJ_PARTY', 'HOSPITAL_PARTY')",
      name: "anticipation_risk_rules_scope_type_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "decision IN ('ALLOW', 'REVIEW', 'BLOCK')",
      name: "anticipation_risk_rules_decision_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "(scope_type = 'TENANT_DEFAULT' AND scope_party_id IS NULL) OR (scope_type <> 'TENANT_DEFAULT' AND scope_party_id IS NOT NULL)",
      name: "anticipation_risk_rules_scope_party_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "max_single_request_amount IS NULL OR max_single_request_amount > 0",
      name: "anticipation_risk_rules_single_amount_positive_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "max_daily_requested_amount IS NULL OR max_daily_requested_amount > 0",
      name: "anticipation_risk_rules_daily_amount_positive_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "max_outstanding_exposure_amount IS NULL OR max_outstanding_exposure_amount > 0",
      name: "anticipation_risk_rules_outstanding_amount_positive_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "max_open_requests_count IS NULL OR max_open_requests_count > 0",
      name: "anticipation_risk_rules_open_count_positive_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "effective_until IS NULL OR effective_from IS NULL OR effective_until >= effective_from",
      name: "anticipation_risk_rules_effective_window_check"
    )
    add_check_constraint(
      :anticipation_risk_rules,
      "max_single_request_amount IS NOT NULL OR max_daily_requested_amount IS NOT NULL OR max_outstanding_exposure_amount IS NOT NULL OR max_open_requests_count IS NOT NULL",
      name: "anticipation_risk_rules_requires_any_limit_check"
    )

    add_index(
      :anticipation_risk_rules,
      %i[tenant_id active scope_type scope_party_id],
      name: "index_anticipation_risk_rules_active_scope"
    )
    add_index(
      :anticipation_risk_rules,
      %i[tenant_id priority created_at],
      name: "index_anticipation_risk_rules_priority"
    )

    enable_tenant_rls("anticipation_risk_rules")
  end

  def down
    drop_table :anticipation_risk_rules
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
