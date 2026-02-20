class ConvertUserReferencesToUuidOnly < ActiveRecord::Migration[8.2]
  def up
    add_missing_uuid_columns!
    backfill_uuid_columns!
    ensure_uuid_foreign_keys!
    replace_bigint_indexes_with_uuid_indexes!
    enforce_uuid_not_null_columns!
    remove_bigint_foreign_keys_and_columns!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "UUID-only user references migration cannot be safely reversed."
  end

  private

  def add_missing_uuid_columns!
    add_column :user_roles, :user_uuid_id, :uuid unless column_exists?(:user_roles, :user_uuid_id)
    add_column :user_roles, :assigned_by_user_uuid_id, :uuid unless column_exists?(:user_roles, :assigned_by_user_uuid_id)
    add_column :webauthn_credentials, :user_uuid_id, :uuid unless column_exists?(:webauthn_credentials, :user_uuid_id)
  end

  def backfill_uuid_columns!
    execute <<~SQL
      UPDATE sessions
      SET user_uuid_id = users.uuid_id
      FROM users
      WHERE sessions.user_uuid_id IS NULL
        AND sessions.user_id = users.id;
    SQL

    execute <<~SQL
      UPDATE api_access_tokens
      SET user_uuid_id = users.uuid_id
      FROM users
      WHERE api_access_tokens.user_uuid_id IS NULL
        AND api_access_tokens.user_id = users.id;
    SQL

    execute <<~SQL
      UPDATE partner_applications
      SET created_by_user_uuid_id = users.uuid_id
      FROM users
      WHERE partner_applications.created_by_user_uuid_id IS NULL
        AND partner_applications.created_by_user_id = users.id;
    SQL

    execute <<~SQL
      UPDATE user_roles
      SET user_uuid_id = users.uuid_id
      FROM users
      WHERE user_roles.user_uuid_id IS NULL
        AND user_roles.user_id = users.id;
    SQL

    execute <<~SQL
      UPDATE user_roles
      SET assigned_by_user_uuid_id = users.uuid_id
      FROM users
      WHERE user_roles.assigned_by_user_uuid_id IS NULL
        AND user_roles.assigned_by_user_id IS NOT NULL
        AND user_roles.assigned_by_user_id = users.id;
    SQL

    execute <<~SQL
      UPDATE webauthn_credentials
      SET user_uuid_id = users.uuid_id
      FROM users
      WHERE webauthn_credentials.user_uuid_id IS NULL
        AND webauthn_credentials.user_id = users.id;
    SQL
  end

  def ensure_uuid_foreign_keys!
    add_foreign_key :user_roles, :users, column: :user_uuid_id, primary_key: :uuid_id unless foreign_key_exists?(:user_roles, :users, column: :user_uuid_id)
    add_foreign_key :user_roles, :users, column: :assigned_by_user_uuid_id, primary_key: :uuid_id unless foreign_key_exists?(:user_roles, :users, column: :assigned_by_user_uuid_id)
    add_foreign_key :webauthn_credentials, :users, column: :user_uuid_id, primary_key: :uuid_id unless foreign_key_exists?(:webauthn_credentials, :users, column: :user_uuid_id)
  end

  def replace_bigint_indexes_with_uuid_indexes!
    remove_index :sessions, name: "index_sessions_on_tenant_id_and_user_id", if_exists: true
    remove_index :sessions, :user_id, if_exists: true
    add_index :sessions, %i[tenant_id user_uuid_id], name: "index_sessions_on_tenant_id_and_user_uuid_id" unless index_exists?(:sessions, %i[tenant_id user_uuid_id], name: "index_sessions_on_tenant_id_and_user_uuid_id")

    remove_index :api_access_tokens, :user_id, if_exists: true

    remove_index :partner_applications, :created_by_user_id, if_exists: true

    remove_index :user_roles, name: "index_user_roles_on_tenant_user", if_exists: true
    remove_index :user_roles, :user_id, if_exists: true
    remove_index :user_roles, :assigned_by_user_id, if_exists: true
    add_index :user_roles, %i[tenant_id user_uuid_id], unique: true, name: "index_user_roles_on_tenant_user_uuid" unless index_exists?(:user_roles, %i[tenant_id user_uuid_id], name: "index_user_roles_on_tenant_user_uuid")
    add_index :user_roles, :user_uuid_id unless index_exists?(:user_roles, :user_uuid_id)
    add_index :user_roles, :assigned_by_user_uuid_id unless index_exists?(:user_roles, :assigned_by_user_uuid_id)

    remove_index :webauthn_credentials, name: "index_webauthn_credentials_on_tenant_user_credential", if_exists: true
    remove_index :webauthn_credentials, :user_id, if_exists: true
    add_index :webauthn_credentials, %i[tenant_id user_uuid_id webauthn_id], unique: true, name: "index_webauthn_credentials_on_tenant_user_uuid_credential" unless index_exists?(:webauthn_credentials, %i[tenant_id user_uuid_id webauthn_id], name: "index_webauthn_credentials_on_tenant_user_uuid_credential")
    add_index :webauthn_credentials, :user_uuid_id unless index_exists?(:webauthn_credentials, :user_uuid_id)
  end

  def enforce_uuid_not_null_columns!
    change_column_null :sessions, :user_uuid_id, false
    change_column_null :user_roles, :user_uuid_id, false
    change_column_null :webauthn_credentials, :user_uuid_id, false
  end

  def remove_bigint_foreign_keys_and_columns!
    remove_foreign_key :sessions, column: :user_id, if_exists: true
    remove_foreign_key :api_access_tokens, column: :user_id, if_exists: true
    remove_foreign_key :partner_applications, column: :created_by_user_id, if_exists: true
    remove_foreign_key :user_roles, column: :user_id, if_exists: true
    remove_foreign_key :user_roles, column: :assigned_by_user_id, if_exists: true
    remove_foreign_key :webauthn_credentials, column: :user_id, if_exists: true

    remove_column :sessions, :user_id, if_exists: true
    remove_column :api_access_tokens, :user_id, if_exists: true
    remove_column :partner_applications, :created_by_user_id, if_exists: true
    remove_column :user_roles, :user_id, if_exists: true
    remove_column :user_roles, :assigned_by_user_id, if_exists: true
    remove_column :webauthn_credentials, :user_id, if_exists: true
  end
end
