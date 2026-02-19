class AddWebauthnSecondFactorForAdminDashboard < ActiveRecord::Migration[8.2]
  def up
    add_column :users, :webauthn_id, :string
    add_index :users, %i[tenant_id webauthn_id],
      unique: true,
      where: "webauthn_id IS NOT NULL",
      name: "index_users_on_tenant_id_and_webauthn_id"

    add_column :sessions, :admin_webauthn_verified_at, :datetime

    create_table :webauthn_credentials, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :user, null: false, type: :bigint, foreign_key: true
      t.string :webauthn_id, null: false
      t.text :public_key, null: false
      t.bigint :sign_count, null: false, default: 0
      t.string :nickname
      t.datetime :last_used_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint :webauthn_credentials, "sign_count >= 0", name: "webauthn_credentials_sign_count_non_negative_check"
    add_index :webauthn_credentials, %i[tenant_id user_id webauthn_id], unique: true, name: "index_webauthn_credentials_on_tenant_user_credential"
    add_index :webauthn_credentials, %i[tenant_id webauthn_id], unique: true, name: "index_webauthn_credentials_on_tenant_credential"

    execute <<~SQL
      ALTER TABLE webauthn_credentials ENABLE ROW LEVEL SECURITY;
      ALTER TABLE webauthn_credentials FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS webauthn_credentials_tenant_policy ON webauthn_credentials;
      CREATE POLICY webauthn_credentials_tenant_policy
      ON webauthn_credentials
      USING (tenant_id = app_current_tenant_id())
      WITH CHECK (tenant_id = app_current_tenant_id());
    SQL
  end

  def down
    drop_table :webauthn_credentials
    remove_column :sessions, :admin_webauthn_verified_at
    remove_index :users, name: "index_users_on_tenant_id_and_webauthn_id"
    remove_column :users, :webauthn_id
  end
end
