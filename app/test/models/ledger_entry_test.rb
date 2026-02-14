require "test_helper"

class LedgerEntryTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @txn_id = SecureRandom.uuid
  end

  test "validates entry_side must be DEBIT or CREDIT" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      entry = build_entry(entry_side: "INVALID")
      assert_not entry.valid?
      assert_includes entry.errors[:entry_side].join, "is not included"
    end
  end

  test "validates amount must be positive" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      entry = build_entry(amount: BigDecimal("0"))
      assert_not entry.valid?
      assert_includes entry.errors[:amount].join, "greater than"

      entry2 = build_entry(amount: BigDecimal("-1.00"))
      assert_not entry2.valid?
      assert_includes entry2.errors[:amount].join, "greater than"
    end
  end

  test "validates account_code must be in ChartOfAccounts" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      entry = build_entry(account_code: "nonexistent:account")
      assert_not entry.valid?
      assert_includes entry.errors[:account_code].join, "not a recognized"
    end
  end

  test "validates currency must be BRL" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      entry = build_entry(currency: "USD")
      assert_not entry.valid?
      assert_includes entry.errors[:currency].join, "is not included"
    end
  end

  test "validates required fields" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      entry = LedgerEntry.new
      assert_not entry.valid?
      assert_includes entry.errors[:txn_id], "can't be blank"
      assert_includes entry.errors[:source_type], "can't be blank"
      assert_includes entry.errors[:source_id], "can't be blank"
      assert_includes entry.errors[:posted_at], "can't be blank"
    end
  end

  test "scope debits returns only DEBIT entries" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      source_id = SecureRandom.uuid
      create_balanced_pair!(source_id: source_id)

      debits = LedgerEntry.where(tenant_id: @tenant.id, txn_id: @txn_id).debits
      assert_equal 1, debits.count
      assert debits.all? { |e| e.entry_side == "DEBIT" }
    end
  end

  test "scope credits returns only CREDIT entries" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      source_id = SecureRandom.uuid
      create_balanced_pair!(source_id: source_id)

      credits = LedgerEntry.where(tenant_id: @tenant.id, txn_id: @txn_id).credits
      assert_equal 1, credits.count
      assert credits.all? { |e| e.entry_side == "CREDIT" }
    end
  end

  test "scope for_account filters by account_code" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      source_id = SecureRandom.uuid
      create_balanced_pair!(source_id: source_id)

      results = LedgerEntry.where(tenant_id: @tenant.id).for_account("clearing:settlement")
      assert_equal 1, results.count
      assert_equal "clearing:settlement", results.first.account_code
    end
  end

  test "scope for_transaction filters by txn_id" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      source_id = SecureRandom.uuid
      create_balanced_pair!(source_id: source_id)

      other_txn = SecureRandom.uuid
      results_mine = LedgerEntry.where(tenant_id: @tenant.id).for_transaction(@txn_id)
      results_other = LedgerEntry.where(tenant_id: @tenant.id).for_transaction(other_txn)

      assert_equal 2, results_mine.count
      assert_equal 0, results_other.count
    end
  end

  test "balance_for returns correct net balance for asset account" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      source_id = SecureRandom.uuid
      create_balanced_pair!(source_id: source_id)

      # clearing:settlement got a DEBIT of 100, so asset-like balance = 100
      balance = LedgerEntry.balance_for("clearing:settlement", tenant_id: @tenant.id)
      assert_equal BigDecimal("100.00"), balance.to_d

      # receivables:hospital got a CREDIT of 100, asset account => debit - credit = -100
      balance2 = LedgerEntry.balance_for("receivables:hospital", tenant_id: @tenant.id)
      assert_equal BigDecimal("-100.00"), balance2.to_d
    end
  end

  test "balance_for returns correct net balance for liability account" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      source_id = SecureRandom.uuid
      txn_id = SecureRandom.uuid
      insert_entries_for_transaction!(
        txn_id: txn_id,
        source_id: source_id,
        rows: [
          { account_code: "obligations:beneficiary", entry_side: "CREDIT", amount: BigDecimal("50.00") },
          { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("50.00") }
        ]
      )

      # liability: credit - debit = 50 - 0 = 50
      balance = LedgerEntry.balance_for("obligations:beneficiary", tenant_id: @tenant.id)
      assert_equal BigDecimal("50.00"), balance.to_d
    end
  end

  private

  def build_entry(overrides = {})
    LedgerEntry.new({
      tenant_id: @tenant.id,
      txn_id: @txn_id,
      entry_position: 1,
      txn_entry_count: 2,
      account_code: "clearing:settlement",
      entry_side: "DEBIT",
      amount: BigDecimal("100.00"),
      currency: "BRL",
      source_type: "Test",
      source_id: SecureRandom.uuid,
      posted_at: Time.current
    }.merge(overrides))
  end

  def create_balanced_pair!(source_id:)
    insert_entries_for_transaction!(
      txn_id: @txn_id,
      source_id: source_id,
      rows: [
        { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("100.00") },
        { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("100.00") }
      ]
    )
  end

  def insert_entries_for_transaction!(txn_id:, source_id:, rows:)
    create_ledger_transaction_header!(txn_id: txn_id, source_id: source_id, entry_count: rows.length)

    posted_at = Time.current
    now = Time.current
    total_entries = rows.length
    payload = rows.each_with_index.map do |row, index|
      {
        tenant_id: @tenant.id,
        txn_id: txn_id,
        entry_position: index + 1,
        txn_entry_count: total_entries,
        account_code: row.fetch(:account_code),
        entry_side: row.fetch(:entry_side),
        amount: row.fetch(:amount),
        currency: "BRL",
        source_type: "Test",
        source_id: source_id,
        posted_at: posted_at,
        created_at: now,
        updated_at: now
      }
    end

    LedgerEntry.insert_all!(payload)
  end

  def create_ledger_transaction_header!(txn_id:, source_id:, entry_count:, source_type: "Test", payment_reference: nil, receivable_id: nil)
    LedgerTransaction.create!(
      tenant_id: @tenant.id,
      txn_id: txn_id,
      source_type: source_type,
      source_id: source_id,
      receivable_id: receivable_id,
      payment_reference: payment_reference,
      payload_hash: "0" * 64,
      entry_count: entry_count,
      posted_at: Time.current,
      metadata: {}
    )
  end
end
