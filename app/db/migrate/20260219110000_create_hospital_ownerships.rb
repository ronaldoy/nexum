class CreateHospitalOwnerships < ActiveRecord::Migration[8.2]
  def up
    create_table :hospital_ownerships, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :organization_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.references :hospital_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :hospital_ownerships,
      "organization_party_id <> hospital_party_id",
      name: "hospital_ownerships_distinct_parties_check"
    )
    add_index(
      :hospital_ownerships,
      %i[tenant_id organization_party_id hospital_party_id],
      unique: true,
      name: "index_hospital_ownerships_on_tenant_org_hospital"
    )
    add_index(
      :hospital_ownerships,
      %i[tenant_id hospital_party_id],
      unique: true,
      where: "active = TRUE",
      name: "index_hospital_ownerships_on_tenant_active_hospital"
    )

    enable_tenant_rls("hospital_ownerships")
  end

  def down
    drop_table :hospital_ownerships
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
