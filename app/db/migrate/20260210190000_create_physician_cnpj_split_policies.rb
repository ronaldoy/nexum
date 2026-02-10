class CreatePhysicianCnpjSplitPolicies < ActiveRecord::Migration[8.2]
  POLICY_SCOPES = %w[SHARED_CNPJ].freeze
  POLICY_STATUSES = %w[ACTIVE INACTIVE].freeze

  def change
    create_table :physician_cnpj_split_policies, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :legal_entity_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.string :scope, null: false, default: "SHARED_CNPJ"
      t.decimal :cnpj_share_rate, precision: 12, scale: 8, null: false, default: 0.3
      t.decimal :physician_share_rate, precision: 12, scale: 8, null: false, default: 0.7
      t.string :status, null: false, default: "ACTIVE"
      t.datetime :effective_from, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :effective_until
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint :physician_cnpj_split_policies, "scope IN ('#{POLICY_SCOPES.join("','")}')", name: "physician_cnpj_split_policies_scope_check"
    add_check_constraint :physician_cnpj_split_policies, "status IN ('#{POLICY_STATUSES.join("','")}')", name: "physician_cnpj_split_policies_status_check"
    add_check_constraint :physician_cnpj_split_policies, "cnpj_share_rate >= 0 AND cnpj_share_rate <= 1", name: "physician_cnpj_split_policies_cnpj_rate_check"
    add_check_constraint :physician_cnpj_split_policies, "physician_share_rate >= 0 AND physician_share_rate <= 1", name: "physician_cnpj_split_policies_physician_rate_check"
    add_check_constraint :physician_cnpj_split_policies, "(cnpj_share_rate + physician_share_rate) = 1.00000000", name: "physician_cnpj_split_policies_total_rate_check"

    add_index :physician_cnpj_split_policies,
      %i[tenant_id legal_entity_party_id scope effective_from],
      name: "index_physician_cnpj_split_policies_lookup"

    add_index :physician_cnpj_split_policies,
      %i[tenant_id legal_entity_party_id scope status],
      unique: true,
      where: "status = 'ACTIVE'",
      name: "index_physician_cnpj_split_policies_active_unique"

    execute <<~SQL
      ALTER TABLE physician_cnpj_split_policies ENABLE ROW LEVEL SECURITY;
      ALTER TABLE physician_cnpj_split_policies FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS physician_cnpj_split_policies_tenant_policy ON physician_cnpj_split_policies;
      CREATE POLICY physician_cnpj_split_policies_tenant_policy
      ON physician_cnpj_split_policies
      USING (tenant_id = app_current_tenant_id())
      WITH CHECK (tenant_id = app_current_tenant_id());
    SQL
  end
end
