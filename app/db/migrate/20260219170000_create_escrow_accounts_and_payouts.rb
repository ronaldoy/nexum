class CreateEscrowAccountsAndPayouts < ActiveRecord::Migration[8.2]
  PROVIDERS = %w[QITECH STARKBANK].freeze
  ESCROW_ACCOUNT_STATUSES = %w[PENDING ACTIVE REJECTED FAILED CLOSED].freeze
  ESCROW_PAYOUT_STATUSES = %w[PENDING SENT FAILED].freeze

  def up
    create_table :escrow_accounts, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :party, null: false, type: :uuid, foreign_key: true
      t.string :provider, null: false
      t.string :account_type, null: false, default: "ESCROW"
      t.string :status, null: false, default: "PENDING"
      t.string :provider_account_id
      t.string :provider_request_id
      t.datetime :last_synced_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :escrow_accounts,
      "provider IN ('#{PROVIDERS.join("','")}')",
      name: "escrow_accounts_provider_check"
    )
    add_check_constraint(
      :escrow_accounts,
      "account_type = 'ESCROW'",
      name: "escrow_accounts_account_type_check"
    )
    add_check_constraint(
      :escrow_accounts,
      "status IN ('#{ESCROW_ACCOUNT_STATUSES.join("','")}')",
      name: "escrow_accounts_status_check"
    )
    add_index(
      :escrow_accounts,
      %i[tenant_id party_id provider],
      unique: true,
      name: "index_escrow_accounts_on_tenant_party_provider"
    )
    add_index(
      :escrow_accounts,
      %i[tenant_id provider provider_account_id],
      unique: true,
      where: "provider_account_id IS NOT NULL",
      name: "index_escrow_accounts_on_tenant_provider_account"
    )
    add_index(
      :escrow_accounts,
      %i[tenant_id status],
      name: "index_escrow_accounts_on_tenant_status"
    )

    create_table :escrow_payouts, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :anticipation_request, null: false, type: :uuid, foreign_key: true
      t.references :party, null: false, type: :uuid, foreign_key: true
      t.references :escrow_account, null: false, type: :uuid, foreign_key: true
      t.string :provider, null: false
      t.string :status, null: false, default: "PENDING"
      t.decimal :amount, precision: 18, scale: 2, null: false
      t.string :currency, null: false, limit: 3, default: "BRL"
      t.string :idempotency_key, null: false
      t.string :provider_transfer_id
      t.datetime :requested_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :processed_at
      t.string :last_error_code
      t.string :last_error_message
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :escrow_payouts,
      "provider IN ('#{PROVIDERS.join("','")}')",
      name: "escrow_payouts_provider_check"
    )
    add_check_constraint(
      :escrow_payouts,
      "status IN ('#{ESCROW_PAYOUT_STATUSES.join("','")}')",
      name: "escrow_payouts_status_check"
    )
    add_check_constraint(
      :escrow_payouts,
      "amount > 0",
      name: "escrow_payouts_amount_positive_check"
    )
    add_check_constraint(
      :escrow_payouts,
      "currency = 'BRL'",
      name: "escrow_payouts_currency_brl_check"
    )
    add_check_constraint(
      :escrow_payouts,
      "btrim(idempotency_key) <> ''",
      name: "escrow_payouts_idempotency_key_present_check"
    )
    add_index(
      :escrow_payouts,
      %i[tenant_id idempotency_key],
      unique: true,
      name: "index_escrow_payouts_on_tenant_idempotency_key"
    )
    add_index(
      :escrow_payouts,
      %i[tenant_id provider provider_transfer_id],
      unique: true,
      where: "provider_transfer_id IS NOT NULL",
      name: "index_escrow_payouts_on_tenant_provider_transfer"
    )
    add_index(
      :escrow_payouts,
      %i[tenant_id anticipation_request_id party_id],
      unique: true,
      name: "index_escrow_payouts_on_tenant_anticipation_party"
    )
    add_index(
      :escrow_payouts,
      %i[tenant_id status requested_at],
      name: "index_escrow_payouts_on_tenant_status_requested_at"
    )

    enable_tenant_rls("escrow_accounts")
    enable_tenant_rls("escrow_payouts")
  end

  def down
    drop_table :escrow_payouts
    drop_table :escrow_accounts
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
