class HardenAuthRlsAndSettlementIdempotency < ActiveRecord::Migration[8.2]
  def up
    harden_sessions!
    harden_settlement_idempotency!
    harden_assignment_contract_idempotency!
    add_ledger_actor_tracking!
    enforce_auth_rls!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Security hardening migration cannot be safely reverted."
  end

  private

  def harden_sessions!
    return if column_exists?(:sessions, :tenant_id)

    add_reference :sessions, :tenant, type: :uuid, foreign_key: true, null: true

    execute <<~SQL
      UPDATE sessions
      SET tenant_id = users.tenant_id
      FROM users
      WHERE sessions.user_id = users.id
        AND sessions.tenant_id IS NULL;
    SQL

    change_column_null :sessions, :tenant_id, false
    unless index_exists?(:sessions, %i[tenant_id user_id], name: "index_sessions_on_tenant_id_and_user_id")
      add_index :sessions, %i[tenant_id user_id], name: "index_sessions_on_tenant_id_and_user_id"
    end
  end

  def harden_settlement_idempotency!
    unless column_exists?(:receivable_payment_settlements, :idempotency_key)
      add_column :receivable_payment_settlements, :idempotency_key, :string
    end

    execute <<~SQL
      UPDATE receivable_payment_settlements
      SET idempotency_key = COALESCE(
        NULLIF(btrim(idempotency_key), ''),
        NULLIF(btrim(payment_reference), ''),
        NULLIF(btrim(request_id), ''),
        'settlement:' || id::text
      )
      WHERE idempotency_key IS NULL OR btrim(idempotency_key) = '';
    SQL

    execute <<~SQL
      UPDATE receivable_payment_settlements
      SET payment_reference = idempotency_key
      WHERE payment_reference IS NULL OR btrim(payment_reference) = '';
    SQL

    change_column_null :receivable_payment_settlements, :idempotency_key, false
    change_column_null :receivable_payment_settlements, :payment_reference, false

    unless check_constraint_exists?(:receivable_payment_settlements, name: "receivable_payment_settlements_idempotency_key_present_check")
      add_check_constraint(
        :receivable_payment_settlements,
        "btrim(idempotency_key) <> ''",
        name: "receivable_payment_settlements_idempotency_key_present_check"
      )
    end
    unless check_constraint_exists?(:receivable_payment_settlements, name: "receivable_payment_settlements_payment_reference_present_check")
      add_check_constraint(
        :receivable_payment_settlements,
        "btrim(payment_reference) <> ''",
        name: "receivable_payment_settlements_payment_reference_present_check"
      )
    end

    if index_exists?(:receivable_payment_settlements, %i[tenant_id payment_reference], name: "idx_rps_tenant_payment_ref")
      remove_index :receivable_payment_settlements, name: "idx_rps_tenant_payment_ref"
    end

    unless index_exists?(:receivable_payment_settlements, %i[tenant_id payment_reference], name: "idx_rps_tenant_payment_ref")
      add_index :receivable_payment_settlements, %i[tenant_id payment_reference], unique: true, name: "idx_rps_tenant_payment_ref"
    end
    unless index_exists?(:receivable_payment_settlements, %i[tenant_id idempotency_key], name: "idx_rps_tenant_idempotency_key")
      add_index :receivable_payment_settlements, %i[tenant_id idempotency_key], unique: true, name: "idx_rps_tenant_idempotency_key"
    end
  end

  def harden_assignment_contract_idempotency!
    execute <<~SQL
      UPDATE assignment_contracts
      SET idempotency_key = COALESCE(
        NULLIF(btrim(idempotency_key), ''),
        NULLIF(btrim(contract_number), '') || ':' || id::text
      )
      WHERE idempotency_key IS NULL OR btrim(idempotency_key) = '';
    SQL

    change_column_null :assignment_contracts, :idempotency_key, false

    unless check_constraint_exists?(:assignment_contracts, name: "assignment_contracts_idempotency_key_present_check")
      add_check_constraint(
        :assignment_contracts,
        "btrim(idempotency_key) <> ''",
        name: "assignment_contracts_idempotency_key_present_check"
      )
    end

    if index_exists?(:assignment_contracts, %i[tenant_id idempotency_key], name: "index_assignment_contracts_on_tenant_idempotency_key")
      remove_index :assignment_contracts, name: "index_assignment_contracts_on_tenant_idempotency_key"
    end

    unless index_exists?(:assignment_contracts, %i[tenant_id idempotency_key], name: "index_assignment_contracts_on_tenant_idempotency_key")
      add_index(
        :assignment_contracts,
        %i[tenant_id idempotency_key],
        unique: true,
        name: "index_assignment_contracts_on_tenant_idempotency_key"
      )
    end
  end

  def add_ledger_actor_tracking!
    add_column :ledger_transactions, :actor_party_id, :uuid unless column_exists?(:ledger_transactions, :actor_party_id)
    add_column :ledger_transactions, :actor_role, :string unless column_exists?(:ledger_transactions, :actor_role)
    add_column :ledger_transactions, :request_id, :string unless column_exists?(:ledger_transactions, :request_id)

    unless foreign_key_exists?(:ledger_transactions, :parties, column: :actor_party_id)
      add_foreign_key :ledger_transactions, :parties, column: :actor_party_id
    end

    unless index_exists?(:ledger_transactions, %i[tenant_id actor_party_id], name: "idx_ledger_transactions_tenant_actor")
      add_index :ledger_transactions, %i[tenant_id actor_party_id], name: "idx_ledger_transactions_tenant_actor"
    end
  end

  def enforce_auth_rls!
    enable_tenant_rls(
      table_name: "users",
      policy_name: "users_tenant_policy",
      using_expression: "tenant_id = app_current_tenant_id()",
      with_check_expression: "tenant_id = app_current_tenant_id()"
    )
    enable_tenant_rls(
      table_name: "sessions",
      policy_name: "sessions_tenant_policy",
      using_expression: "tenant_id = app_current_tenant_id()",
      with_check_expression: "tenant_id = app_current_tenant_id()"
    )
    enable_tenant_rls(
      table_name: "tenants",
      policy_name: "tenants_self_policy",
      using_expression: "id = app_current_tenant_id()",
      with_check_expression: "id = app_current_tenant_id()"
    )
  end

  def enable_tenant_rls(table_name:, policy_name:, using_expression:, with_check_expression:)
    execute <<~SQL
      ALTER TABLE #{table_name} ENABLE ROW LEVEL SECURITY;
      ALTER TABLE #{table_name} FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS #{policy_name} ON #{table_name};
      CREATE POLICY #{policy_name}
      ON #{table_name}
      USING (#{using_expression})
      WITH CHECK (#{with_check_expression});
    SQL
  end
end
