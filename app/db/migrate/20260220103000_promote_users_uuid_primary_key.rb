class PromoteUsersUuidPrimaryKey < ActiveRecord::Migration[8.2]
  def up
    return unless column_exists?(:users, :id)

    ensure_users_uuid_column_ready!
    ensure_no_foreign_keys_to_legacy_users_id!
    promote_users_primary_key_to_uuid!
    drop_legacy_users_bigint_id!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Users UUID primary key promotion cannot be safely reversed."
  end

  private

  def ensure_users_uuid_column_ready!
    raise ActiveRecord::IrreversibleMigration, "users.uuid_id is required" unless column_exists?(:users, :uuid_id)

    change_column_null :users, :uuid_id, false

    return if index_exists?(:users, :uuid_id, unique: true)

    add_index :users, :uuid_id, unique: true
  end

  def ensure_no_foreign_keys_to_legacy_users_id!
    count = ActiveRecord::Base.connection.select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.confrelid
      JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(c.confkey)
      WHERE c.contype = 'f'
        AND t.relname = 'users'
        AND a.attname = 'id';
    SQL

    return if count.zero?

    raise ActiveRecord::IrreversibleMigration, "Foreign keys still reference users.id; aborting UUID PK promotion."
  end

  def promote_users_primary_key_to_uuid!
    return if users_primary_key_columns == [ "uuid_id" ]

    execute <<~SQL
      DO $$
      DECLARE
        current_pk_name text;
      BEGIN
        SELECT conname INTO current_pk_name
        FROM pg_constraint
        WHERE conrelid = 'users'::regclass
          AND contype = 'p';

        IF current_pk_name IS NOT NULL THEN
          EXECUTE format('ALTER TABLE users DROP CONSTRAINT %I', current_pk_name);
        END IF;
      END
      $$;
    SQL

    execute "ALTER TABLE users ADD CONSTRAINT users_pkey PRIMARY KEY USING INDEX index_users_on_uuid_id"
  end

  def drop_legacy_users_bigint_id!
    execute "ALTER TABLE users ALTER COLUMN id DROP DEFAULT"

    remove_column :users, :id, :bigint

    execute "DROP SEQUENCE IF EXISTS users_id_seq"
  end

  def users_primary_key_columns
    ActiveRecord::Base.connection.select_values(<<~SQL)
      SELECT a.attname
      FROM pg_index i
      JOIN pg_class t ON t.oid = i.indrelid
      JOIN unnest(i.indkey) WITH ORDINALITY AS key(attnum, ordinality) ON true
      JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = key.attnum
      WHERE t.relname = 'users'
        AND i.indisprimary
      ORDER BY key.ordinality;
    SQL
  end
end
