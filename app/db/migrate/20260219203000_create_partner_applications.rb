class CreatePartnerApplications < ActiveRecord::Migration[8.2]
  def up
    create_table :partner_applications, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :created_by_user, type: :bigint, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :client_id, null: false
      t.string :client_secret_digest, null: false
      t.text :scopes, array: true, null: false, default: []
      t.integer :token_ttl_minutes, null: false, default: 15
      t.text :allowed_origins, array: true, null: false, default: []
      t.boolean :active, null: false, default: true
      t.datetime :last_used_at
      t.datetime :rotated_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :partner_applications,
      "btrim(name) <> ''",
      name: "partner_applications_name_present_check"
    )
    add_check_constraint(
      :partner_applications,
      "btrim(client_id) <> ''",
      name: "partner_applications_client_id_present_check"
    )
    add_check_constraint(
      :partner_applications,
      "btrim(client_secret_digest) <> ''",
      name: "partner_applications_client_secret_digest_present_check"
    )
    add_check_constraint(
      :partner_applications,
      "token_ttl_minutes BETWEEN 5 AND 60",
      name: "partner_applications_token_ttl_range_check"
    )

    add_index :partner_applications, :client_id, unique: true
    add_index :partner_applications, %i[tenant_id active created_at], name: "index_partner_applications_tenant_active_created"

    enable_tenant_rls("partner_applications")
  end

  def down
    drop_table :partner_applications
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
