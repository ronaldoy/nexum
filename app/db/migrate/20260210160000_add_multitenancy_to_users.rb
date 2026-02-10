class AddMultitenancyToUsers < ActiveRecord::Migration[8.2]
  def up
    add_reference :users, :tenant, type: :uuid, foreign_key: true
    add_reference :users, :party, type: :uuid, foreign_key: true
    add_column :users, :role, :string, null: false, default: "supplier_user"

    assign_default_tenant_to_existing_users!

    change_column_null :users, :tenant_id, false
  end

  def down
    remove_column :users, :role
    remove_reference :users, :party, foreign_key: true
    remove_reference :users, :tenant, foreign_key: true
  end

  private

  def assign_default_tenant_to_existing_users!
    users_count = select_value("SELECT COUNT(*) FROM users").to_i
    return if users_count.zero?

    tenant_id = select_value("SELECT id::text FROM tenants ORDER BY created_at ASC LIMIT 1")

    if tenant_id.blank?
      execute <<~SQL
        INSERT INTO tenants (id, slug, name, active, metadata, created_at, updated_at)
        VALUES (gen_random_uuid(), 'default', 'Default Tenant', TRUE, '{}'::jsonb, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (slug) DO NOTHING;
      SQL
      tenant_id = select_value("SELECT id::text FROM tenants WHERE slug = 'default' LIMIT 1")
    end

    return if tenant_id.blank?

    execute <<~SQL
      UPDATE users
      SET tenant_id = '#{tenant_id}'
      WHERE tenant_id IS NULL;
    SQL
  end
end
