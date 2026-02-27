class CreateAnticipationRiskDecisions < ActiveRecord::Migration[8.2]
  def up
    create_table :anticipation_risk_decisions, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :anticipation_request, type: :uuid, foreign_key: true
      t.references :receivable, null: false, type: :uuid, foreign_key: true
      t.references :receivable_allocation, type: :uuid, foreign_key: true
      t.references :requester_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.references :scope_party, type: :uuid, foreign_key: { to_table: :parties }
      t.references :trigger_rule, type: :uuid, foreign_key: { to_table: :anticipation_risk_rules }
      t.string :scope_type
      t.string :stage, null: false
      t.string :decision_action, null: false
      t.string :decision_code, null: false
      t.string :decision_metric
      t.decimal :requested_amount, precision: 18, scale: 2, null: false
      t.decimal :net_amount, precision: 18, scale: 2, null: false
      t.string :request_id
      t.string :idempotency_key
      t.datetime :evaluated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :anticipation_risk_decisions,
      "stage IN ('CREATE', 'CONFIRM')",
      name: "anticipation_risk_decisions_stage_check"
    )
    add_check_constraint(
      :anticipation_risk_decisions,
      "decision_action IN ('ALLOW', 'REVIEW', 'BLOCK')",
      name: "anticipation_risk_decisions_action_check"
    )
    add_check_constraint(
      :anticipation_risk_decisions,
      "requested_amount > 0",
      name: "anticipation_risk_decisions_requested_amount_positive_check"
    )
    add_check_constraint(
      :anticipation_risk_decisions,
      "net_amount > 0",
      name: "anticipation_risk_decisions_net_amount_positive_check"
    )

    add_index(
      :anticipation_risk_decisions,
      %i[tenant_id evaluated_at],
      name: "index_anticipation_risk_decisions_tenant_evaluated_at"
    )
    add_index(
      :anticipation_risk_decisions,
      %i[tenant_id receivable_id evaluated_at],
      name: "index_anticipation_risk_decisions_tenant_receivable"
    )
    add_index(
      :anticipation_risk_decisions,
      %i[tenant_id decision_action evaluated_at],
      name: "index_anticipation_risk_decisions_tenant_action"
    )

    execute <<~SQL
      CREATE TRIGGER anticipation_risk_decisions_no_update_delete
      BEFORE UPDATE OR DELETE ON anticipation_risk_decisions
      FOR EACH ROW EXECUTE FUNCTION app_forbid_mutation();
    SQL

    enable_tenant_rls("anticipation_risk_decisions")
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS anticipation_risk_decisions_no_update_delete ON anticipation_risk_decisions;
      DROP POLICY IF EXISTS anticipation_risk_decisions_tenant_policy ON anticipation_risk_decisions;
    SQL

    drop_table :anticipation_risk_decisions
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
