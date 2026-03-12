class AddStarkbankPaymentOperatingModels < ActiveRecord::Migration[8.2]
  PROVIDERS = %w[QITECH STARKBANK].freeze
  RECEIVING_ACCOUNT_STATUSES = %w[ACTIVE INACTIVE].freeze
  ESCROW_PAYOUT_STATUSES = %w[PENDING PROCESSING SENT FAILED].freeze
  ESCROW_PAYOUT_BATCH_STATUSES = %w[OPEN CLOSED FAILED].freeze
  PIX_ACCOUNT_TYPES = %w[checking savings salary payment].freeze

  def up
    create_table :receiving_accounts, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :party, null: false, type: :uuid, foreign_key: true
      t.string :payment_rail, null: false, default: "PIX"
      t.string :status, null: false, default: "ACTIVE"
      t.boolean :primary, null: false, default: true
      t.string :bank_code, null: false
      t.string :branch_code, null: false
      t.string :account_number, null: false
      t.string :account_type, null: false, default: "checking"
      t.string :holder_name, null: false
      t.string :holder_document_number, null: false
      t.string :account_fingerprint, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :receiving_accounts,
      "payment_rail = 'PIX'",
      name: "receiving_accounts_payment_rail_pix_check"
    )
    add_check_constraint(
      :receiving_accounts,
      "status IN ('#{RECEIVING_ACCOUNT_STATUSES.join("','")}')",
      name: "receiving_accounts_status_check"
    )
    add_check_constraint(
      :receiving_accounts,
      "account_type IN ('#{PIX_ACCOUNT_TYPES.join("','")}')",
      name: "receiving_accounts_account_type_check"
    )
    add_check_constraint(
      :receiving_accounts,
      "bank_code ~ '^[0-9]{8}$'",
      name: "receiving_accounts_bank_code_ispb_check"
    )
    add_check_constraint(
      :receiving_accounts,
      "account_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "receiving_accounts_fingerprint_check"
    )
    add_index :receiving_accounts, %i[tenant_id id], unique: true, name: "idx_receiving_accounts_tenant_id_id"
    add_index(
      :receiving_accounts,
      %i[tenant_id party_id account_fingerprint],
      unique: true,
      name: "index_receiving_accounts_on_tenant_party_fingerprint"
    )
    add_index(
      :receiving_accounts,
      %i[tenant_id party_id],
      unique: true,
      where: "status = 'ACTIVE' AND \"primary\" = true",
      name: "index_receiving_accounts_on_tenant_party_primary_active"
    )
    add_index(
      :receiving_accounts,
      %i[tenant_id status updated_at],
      name: "index_receiving_accounts_on_tenant_status_updated_at"
    )

    create_table :escrow_payout_batches, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.string :provider, null: false
      t.string :status, null: false, default: "OPEN"
      t.string :source_provider_account_id, null: false
      t.decimal :risk_limit_amount, precision: 18, scale: 2, null: false
      t.decimal :balance_snapshot_amount, precision: 18, scale: 2, null: false
      t.decimal :reserved_amount, precision: 18, scale: 2, null: false, default: "0.00"
      t.decimal :dispatched_amount, precision: 18, scale: 2, null: false, default: "0.00"
      t.decimal :fee_amount, precision: 18, scale: 2, null: false, default: "0.00"
      t.datetime :started_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :closed_at
      t.datetime :last_polled_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :escrow_payout_batches,
      "provider IN ('#{PROVIDERS.join("','")}')",
      name: "escrow_payout_batches_provider_check"
    )
    add_check_constraint(
      :escrow_payout_batches,
      "status IN ('#{ESCROW_PAYOUT_BATCH_STATUSES.join("','")}')",
      name: "escrow_payout_batches_status_check"
    )
    add_check_constraint(
      :escrow_payout_batches,
      "risk_limit_amount > 0",
      name: "escrow_payout_batches_risk_limit_positive_check"
    )
    add_check_constraint(
      :escrow_payout_batches,
      "balance_snapshot_amount >= 0 AND reserved_amount >= 0 AND dispatched_amount >= 0 AND fee_amount >= 0",
      name: "escrow_payout_batches_non_negative_amounts_check"
    )
    add_check_constraint(
      :escrow_payout_batches,
      "reserved_amount <= risk_limit_amount AND dispatched_amount <= risk_limit_amount",
      name: "escrow_payout_batches_dispatch_limit_check"
    )
    add_index :escrow_payout_batches, %i[tenant_id id], unique: true, name: "idx_escrow_payout_batches_tenant_id_id"
    add_index(
      :escrow_payout_batches,
      %i[tenant_id provider status started_at],
      name: "idx_ep_batches_tenant_provider_status_started"
    )
    add_index(
      :escrow_payout_batches,
      %i[tenant_id provider source_provider_account_id started_at],
      name: "idx_ep_batches_tenant_provider_source_started"
    )

    add_reference :escrow_payouts, :escrow_payout_batch, type: :uuid, foreign_key: false
    add_column :escrow_payouts, :provider_status, :string
    add_column :escrow_payouts, :provider_fee_amount, :decimal, precision: 18, scale: 2, null: false, default: "0.00"
    add_column :escrow_payouts, :provider_fee_currency, :string, limit: 3, null: false, default: "BRL"
    add_column :escrow_payouts, :provider_source_account_id, :string
    add_column :escrow_payouts, :provider_destination_account_id, :string
    add_column :escrow_payouts, :provider_end_to_end_id, :string
    add_column :escrow_payouts, :confirmed_at, :datetime

    remove_check_constraint :escrow_payouts, name: "escrow_payouts_status_check"
    add_check_constraint(
      :escrow_payouts,
      "status IN ('#{ESCROW_PAYOUT_STATUSES.join("','")}')",
      name: "escrow_payouts_status_check"
    )
    add_check_constraint(
      :escrow_payouts,
      "provider_fee_amount >= 0",
      name: "escrow_payouts_provider_fee_amount_non_negative_check"
    )
    add_check_constraint(
      :escrow_payouts,
      "provider_fee_currency = 'BRL'",
      name: "escrow_payouts_provider_fee_currency_brl_check"
    )
    add_index(
      :escrow_payouts,
      %i[tenant_id status confirmed_at requested_at],
      name: "index_escrow_payouts_on_tenant_status_confirmed_requested_at"
    )
    add_index(
      :escrow_payouts,
      %i[tenant_id provider provider_status],
      name: "index_escrow_payouts_on_tenant_provider_provider_status"
    )
    add_index(
      :escrow_payouts,
      %i[tenant_id provider provider_end_to_end_id],
      unique: true,
      where: "provider_end_to_end_id IS NOT NULL",
      name: "index_escrow_payouts_on_tenant_provider_end_to_end"
    )

    add_foreign_key :receiving_accounts, :parties, column: %i[tenant_id party_id], primary_key: %i[tenant_id id], name: "fk_receiving_accounts_tenant_party"
    add_foreign_key :escrow_payouts, :escrow_payout_batches, column: %i[tenant_id escrow_payout_batch_id], primary_key: %i[tenant_id id], name: "fk_escrow_payouts_tenant_batch"

    enable_tenant_rls("receiving_accounts")
    enable_tenant_rls("escrow_payout_batches")
  end

  def down
    execute "DROP POLICY IF EXISTS receiving_accounts_tenant_policy ON receiving_accounts"
    execute "DROP POLICY IF EXISTS escrow_payout_batches_tenant_policy ON escrow_payout_batches"

    remove_foreign_key :escrow_payouts, name: "fk_escrow_payouts_tenant_batch"
    remove_foreign_key :receiving_accounts, name: "fk_receiving_accounts_tenant_party"

    remove_index :escrow_payouts, name: "index_escrow_payouts_on_tenant_provider_end_to_end"
    remove_index :escrow_payouts, name: "index_escrow_payouts_on_tenant_provider_provider_status"
    remove_index :escrow_payouts, name: "index_escrow_payouts_on_tenant_status_confirmed_requested_at"
    remove_check_constraint :escrow_payouts, name: "escrow_payouts_provider_fee_currency_brl_check"
    remove_check_constraint :escrow_payouts, name: "escrow_payouts_provider_fee_amount_non_negative_check"
    remove_check_constraint :escrow_payouts, name: "escrow_payouts_status_check"
    add_check_constraint(
      :escrow_payouts,
      "status IN ('PENDING','SENT','FAILED')",
      name: "escrow_payouts_status_check"
    )
    remove_column :escrow_payouts, :confirmed_at
    remove_column :escrow_payouts, :provider_end_to_end_id
    remove_column :escrow_payouts, :provider_destination_account_id
    remove_column :escrow_payouts, :provider_source_account_id
    remove_column :escrow_payouts, :provider_fee_currency
    remove_column :escrow_payouts, :provider_fee_amount
    remove_column :escrow_payouts, :provider_status
    remove_reference :escrow_payouts, :escrow_payout_batch, foreign_key: false

    drop_table :escrow_payout_batches
    drop_table :receiving_accounts
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
