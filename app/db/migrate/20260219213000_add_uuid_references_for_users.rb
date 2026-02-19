class AddUuidReferencesForUsers < ActiveRecord::Migration[8.2]
  def up
    add_users_uuid_id!
    add_dual_user_reference_columns!
    backfill_dual_user_reference_columns!
    add_dual_user_reference_indexes_and_foreign_keys!
  end

  def down
    remove_dual_user_reference_indexes_and_foreign_keys!
    remove_dual_user_reference_columns!
    remove_users_uuid_id!
  end

  private

  def add_users_uuid_id!
    add_column :users, :uuid_id, :uuid, default: -> { "gen_random_uuid()" }
    execute <<~SQL
      UPDATE users
      SET uuid_id = gen_random_uuid()
      WHERE uuid_id IS NULL;
    SQL
    change_column_null :users, :uuid_id, false
    add_index :users, :uuid_id, unique: true
  end

  def remove_users_uuid_id!
    remove_index :users, :uuid_id, if_exists: true
    remove_column :users, :uuid_id, if_exists: true
  end

  def add_dual_user_reference_columns!
    add_column :sessions, :user_uuid_id, :uuid
    add_column :api_access_tokens, :user_uuid_id, :uuid
    add_column :partner_applications, :created_by_user_uuid_id, :uuid
  end

  def remove_dual_user_reference_columns!
    remove_column :sessions, :user_uuid_id, if_exists: true
    remove_column :api_access_tokens, :user_uuid_id, if_exists: true
    remove_column :partner_applications, :created_by_user_uuid_id, if_exists: true
  end

  def backfill_dual_user_reference_columns!
    execute <<~SQL
      UPDATE sessions
      SET user_uuid_id = users.uuid_id
      FROM users
      WHERE sessions.user_id = users.id
        AND sessions.user_uuid_id IS NULL;
    SQL

    execute <<~SQL
      UPDATE api_access_tokens
      SET user_uuid_id = users.uuid_id
      FROM users
      WHERE api_access_tokens.user_id = users.id
        AND api_access_tokens.user_uuid_id IS NULL;
    SQL

    execute <<~SQL
      UPDATE partner_applications
      SET created_by_user_uuid_id = users.uuid_id
      FROM users
      WHERE partner_applications.created_by_user_id = users.id
        AND partner_applications.created_by_user_uuid_id IS NULL;
    SQL
  end

  def add_dual_user_reference_indexes_and_foreign_keys!
    add_index :sessions, :user_uuid_id
    add_index :api_access_tokens, :user_uuid_id
    add_index :partner_applications, :created_by_user_uuid_id

    add_foreign_key :sessions, :users, column: :user_uuid_id, primary_key: :uuid_id
    add_foreign_key :api_access_tokens, :users, column: :user_uuid_id, primary_key: :uuid_id
    add_foreign_key :partner_applications, :users, column: :created_by_user_uuid_id, primary_key: :uuid_id
  end

  def remove_dual_user_reference_indexes_and_foreign_keys!
    remove_foreign_key :sessions, column: :user_uuid_id, if_exists: true
    remove_foreign_key :api_access_tokens, column: :user_uuid_id, if_exists: true
    remove_foreign_key :partner_applications, column: :created_by_user_uuid_id, if_exists: true

    remove_index :sessions, :user_uuid_id, if_exists: true
    remove_index :api_access_tokens, :user_uuid_id, if_exists: true
    remove_index :partner_applications, :created_by_user_uuid_id, if_exists: true
  end
end
