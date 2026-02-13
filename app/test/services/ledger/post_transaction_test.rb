require "test_helper"

module Ledger
  class PostTransactionTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @request_id = SecureRandom.uuid
    end

    test "creates balanced entries for valid input" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        txn_id = SecureRandom.uuid
        source_id = SecureRandom.uuid

        result = service.call(
          txn_id: txn_id,
          posted_at: Time.current,
          source_type: "Test",
          source_id: source_id,
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("100.00") },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("100.00") }
          ]
        )

        assert_equal 2, result.size
        assert result.all? { |e| e.txn_id == txn_id }
        assert result.all? { |e| e.source_type == "Test" }
        assert result.all? { |e| e.source_id == source_id }

        debit = result.find { |e| e.entry_side == "DEBIT" }
        credit = result.find { |e| e.entry_side == "CREDIT" }
        assert_equal "clearing:settlement", debit.account_code
        assert_equal "receivables:hospital", credit.account_code
        assert_equal BigDecimal("100.00"), debit.amount.to_d
        assert_equal BigDecimal("100.00"), credit.amount.to_d
      end
    end

    test "raises on unbalanced entries" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        error = assert_raises(Ledger::PostTransaction::ValidationError) do
          service.call(
            txn_id: SecureRandom.uuid,
            posted_at: Time.current,
            source_type: "Test",
            source_id: SecureRandom.uuid,
            entries: [
              { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("100.00") },
              { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("99.00") }
            ]
          )
        end

        assert_equal "unbalanced_transaction", error.code
      end
    end

    test "raises on unknown account codes" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        error = assert_raises(Ledger::PostTransaction::ValidationError) do
          service.call(
            txn_id: SecureRandom.uuid,
            posted_at: Time.current,
            source_type: "Test",
            source_id: SecureRandom.uuid,
            entries: [
              { account_code: "fantasy:account", entry_side: "DEBIT", amount: BigDecimal("100.00") },
              { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("100.00") }
            ]
          )
        end

        assert_equal "unknown_account_code", error.code
      end
    end

    test "raises on empty entries" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        error = assert_raises(Ledger::PostTransaction::ValidationError) do
          service.call(
            txn_id: SecureRandom.uuid,
            posted_at: Time.current,
            source_type: "Test",
            source_id: SecureRandom.uuid,
            entries: []
          )
        end

        assert_equal "empty_entries", error.code
      end
    end

    test "raises on invalid entry_side" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        error = assert_raises(Ledger::PostTransaction::ValidationError) do
          service.call(
            txn_id: SecureRandom.uuid,
            posted_at: Time.current,
            source_type: "Test",
            source_id: SecureRandom.uuid,
            entries: [
              { account_code: "clearing:settlement", entry_side: "LEFT", amount: BigDecimal("100.00") },
              { account_code: "receivables:hospital", entry_side: "RIGHT", amount: BigDecimal("100.00") }
            ]
          )
        end

        assert_equal "invalid_entry_side", error.code
      end
    end

    test "applies FinancialRounding.money to all amounts" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        txn_id = SecureRandom.uuid

        result = service.call(
          txn_id: txn_id,
          posted_at: Time.current,
          source_type: "Test",
          source_id: SecureRandom.uuid,
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("100.005") },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("100.005") }
          ]
        )

        # ROUND_UP: 100.005 -> 100.01
        assert_equal BigDecimal("100.01"), result.first.amount.to_d
        assert_equal BigDecimal("100.01"), result.last.amount.to_d
      end
    end

    test "idempotent replay for same txn_id" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        txn_id = SecureRandom.uuid
        source_id = SecureRandom.uuid
        entries = [
          { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("50.00") },
          { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("50.00") }
        ]

        first = service.call(txn_id: txn_id, posted_at: Time.current, source_type: "Test", source_id: source_id, entries: entries)
        second = service.call(txn_id: txn_id, posted_at: Time.current, source_type: "Test", source_id: source_id, entries: entries)

        assert_equal first.map(&:id), second.map(&:id)
        assert_equal 2, LedgerEntry.where(tenant_id: @tenant.id, txn_id: txn_id).count
      end
    end

    test "all entries share same txn_id" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        txn_id = SecureRandom.uuid

        result = service.call(
          txn_id: txn_id,
          posted_at: Time.current,
          source_type: "Test",
          source_id: SecureRandom.uuid,
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("30.00") },
            { account_code: "obligations:cnpj", entry_side: "DEBIT", amount: BigDecimal("20.00") },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("50.00") }
          ]
        )

        assert_equal 3, result.size
        assert result.all? { |e| e.txn_id == txn_id }
      end
    end

    test "sets receivable_id when provided" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        receivable_id = SecureRandom.uuid # not a real FK, just testing the field
        txn_id = SecureRandom.uuid

        # Use a receivable that exists to satisfy FK constraint
        bundle = create_minimal_receivable!
        result = service.call(
          txn_id: txn_id,
          receivable_id: bundle[:receivable].id,
          posted_at: Time.current,
          source_type: "Test",
          source_id: SecureRandom.uuid,
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("10.00") },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("10.00") }
          ]
        )

        assert result.all? { |e| e.receivable_id == bundle[:receivable].id }
      end
    end

    private

    def service
      @service ||= Ledger::PostTransaction.new(tenant_id: @tenant.id, request_id: @request_id)
    end

    def create_minimal_receivable!
      debtor = Party.create!(tenant: @tenant, kind: "HOSPITAL", legal_name: "Hospital Ledger Test", document_number: valid_cnpj_from_seed("ledger-post-txn-hospital"))
      supplier = Party.create!(tenant: @tenant, kind: "SUPPLIER", legal_name: "Fornecedor Ledger Test", document_number: valid_cnpj_from_seed("ledger-post-txn-supplier"))
      kind = ReceivableKind.create!(tenant: @tenant, code: "ledger_post_txn_test", name: "Ledger PostTxn Test", source_family: "SUPPLIER")
      receivable = Receivable.create!(
        tenant: @tenant, receivable_kind: kind,
        debtor_party: debtor, creditor_party: supplier, beneficiary_party: supplier,
        external_reference: "ledger-post-txn-test",
        gross_amount: "100.00", currency: "BRL",
        performed_at: Time.current, due_at: 3.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
      )
      { receivable: receivable, debtor: debtor, supplier: supplier }
    end
  end
end
