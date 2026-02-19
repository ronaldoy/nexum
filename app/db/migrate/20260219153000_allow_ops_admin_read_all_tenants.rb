class AllowOpsAdminReadAllTenants < ActiveRecord::Migration[8.2]
  POLICY_NAME = "tenants_ops_admin_policy".freeze

  def up
    execute <<~SQL
      DROP POLICY IF EXISTS #{POLICY_NAME} ON tenants;
      CREATE POLICY #{POLICY_NAME}
      ON tenants
      FOR SELECT
      USING (current_setting('app.role', true) = 'ops_admin');
    SQL
  end

  def down
    execute <<~SQL
      DROP POLICY IF EXISTS #{POLICY_NAME} ON tenants;
    SQL
  end
end
