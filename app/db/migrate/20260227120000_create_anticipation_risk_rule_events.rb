class CreateAnticipationRiskRuleEvents < ActiveRecord::Migration[8.2]
  def up
    create_table :anticipation_risk_rule_events, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :anticipation_risk_rule, null: false, type: :uuid, foreign_key: true
      t.integer :sequence, null: false
      t.string :event_type, null: false
      t.references :actor_party, type: :uuid, foreign_key: { to_table: :parties }
      t.string :actor_role
      t.string :request_id
      t.datetime :occurred_at, null: false
      t.string :prev_hash
      t.string :event_hash, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :anticipation_risk_rule_events,
      "event_type IN ('RULE_CREATED', 'RULE_UPDATED', 'RULE_ACTIVATED', 'RULE_DEACTIVATED')",
      name: "anticipation_risk_rule_events_event_type_check"
    )

    add_index(
      :anticipation_risk_rule_events,
      %i[tenant_id anticipation_risk_rule_id sequence],
      unique: true,
      name: "index_anticipation_risk_rule_events_unique_sequence"
    )
    add_index :anticipation_risk_rule_events, :event_hash, unique: true

    execute <<~SQL
      CREATE TRIGGER anticipation_risk_rule_events_no_update_delete
      BEFORE UPDATE OR DELETE ON anticipation_risk_rule_events
      FOR EACH ROW EXECUTE FUNCTION app_forbid_mutation();
    SQL

    enable_tenant_rls("anticipation_risk_rule_events")
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS anticipation_risk_rule_events_no_update_delete ON anticipation_risk_rule_events;
      DROP POLICY IF EXISTS anticipation_risk_rule_events_tenant_policy ON anticipation_risk_rule_events;
    SQL

    drop_table :anticipation_risk_rule_events
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
