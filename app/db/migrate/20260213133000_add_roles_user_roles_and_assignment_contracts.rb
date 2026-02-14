class AddRolesUserRolesAndAssignmentContracts < ActiveRecord::Migration[8.2]
  ROLE_CODES = %w[
    hospital_admin
    supplier_user
    ops_admin
    physician_pf_user
    physician_pj_admin
    physician_pj_member
    integration_api
  ].freeze
  ASSIGNMENT_CONTRACT_STATUSES = %w[DRAFT SIGNED ACTIVE SETTLED CANCELLED].freeze

  def up
    create_table :roles, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.string :code, null: false
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :roles, "code IN ('#{ROLE_CODES.join("','")}')", name: "roles_code_check"
    add_index :roles, %i[tenant_id code], unique: true

    create_table :user_roles, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :role, null: false, type: :uuid, foreign_key: true
      t.references :assigned_by_user, foreign_key: { to_table: :users }
      t.datetime :assigned_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :user_roles, %i[tenant_id user_id], unique: true, name: "index_user_roles_on_tenant_user"
    add_index :user_roles, %i[tenant_id role_id], name: "index_user_roles_on_tenant_role"

    create_table :assignment_contracts, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :receivable, null: false, type: :uuid, foreign_key: true
      t.references :anticipation_request, type: :uuid, foreign_key: true
      t.references :assignor_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.references :assignee_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.string :contract_number, null: false
      t.string :status, null: false, default: "DRAFT"
      t.string :currency, null: false, default: "BRL", limit: 3
      t.decimal :assigned_amount, precision: 18, scale: 2, null: false
      t.string :idempotency_key
      t.datetime :signed_at
      t.datetime :effective_at
      t.datetime :cancelled_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :assignment_contracts, "assigned_amount > 0", name: "assignment_contracts_assigned_amount_positive_check"
    add_check_constraint :assignment_contracts, "status IN ('#{ASSIGNMENT_CONTRACT_STATUSES.join("','")}')", name: "assignment_contracts_status_check"
    add_check_constraint :assignment_contracts, "currency = 'BRL'", name: "assignment_contracts_currency_brl_check"
    add_check_constraint :assignment_contracts, "(status IN ('DRAFT','CANCELLED')) OR signed_at IS NOT NULL", name: "assignment_contracts_signed_at_required_check"
    add_check_constraint :assignment_contracts, "(status <> 'CANCELLED') OR cancelled_at IS NOT NULL", name: "assignment_contracts_cancelled_at_required_check"
    add_check_constraint :assignment_contracts, "(cancelled_at IS NULL) OR (status = 'CANCELLED')", name: "assignment_contracts_cancelled_at_state_check"
    add_index :assignment_contracts, %i[tenant_id contract_number], unique: true, name: "index_assignment_contracts_on_tenant_contract_number"
    add_index :assignment_contracts, %i[tenant_id receivable_id], name: "index_assignment_contracts_on_tenant_receivable"
    add_index :assignment_contracts, %i[tenant_id idempotency_key], unique: true, where: "idempotency_key IS NOT NULL", name: "index_assignment_contracts_on_tenant_idempotency_key"

    backfill_roles_and_user_roles!

    remove_column :users, :role, :string

    enable_tenant_rls("roles")
    enable_tenant_rls("user_roles")
    enable_tenant_rls("assignment_contracts")
  end

  def down
    add_column :users, :role, :string, null: false, default: "supplier_user"
    backfill_legacy_user_role!

    drop_table :assignment_contracts
    drop_table :user_roles
    drop_table :roles
  end

  private

  def backfill_roles_and_user_roles!
    execute <<~SQL
      INSERT INTO roles (id, tenant_id, code, name, active, metadata, created_at, updated_at)
      SELECT
        gen_random_uuid(),
        role_rows.tenant_id,
        role_rows.role,
        INITCAP(REPLACE(role_rows.role, '_', ' ')),
        TRUE,
        '{}'::jsonb,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM (
        SELECT DISTINCT tenant_id, role
        FROM users
        WHERE role IS NOT NULL
      ) role_rows
      ON CONFLICT (tenant_id, code) DO NOTHING;
    SQL

    execute <<~SQL
      INSERT INTO user_roles (id, tenant_id, user_id, role_id, assigned_at, metadata, created_at, updated_at)
      SELECT
        gen_random_uuid(),
        users.tenant_id,
        users.id,
        roles.id,
        CURRENT_TIMESTAMP,
        '{}'::jsonb,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM users
      INNER JOIN roles
        ON roles.tenant_id = users.tenant_id
       AND roles.code = users.role
      WHERE users.role IS NOT NULL
      ON CONFLICT (tenant_id, user_id) DO NOTHING;
    SQL
  end

  def backfill_legacy_user_role!
    execute <<~SQL
      WITH selected_role AS (
        SELECT DISTINCT ON (ur.user_id)
          ur.user_id,
          r.code
        FROM user_roles ur
        INNER JOIN roles r ON r.id = ur.role_id
        ORDER BY ur.user_id, ur.assigned_at DESC, ur.created_at DESC, ur.id DESC
      )
      UPDATE users
      SET role = selected_role.code
      FROM selected_role
      WHERE users.id = selected_role.user_id;
    SQL
  end

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
