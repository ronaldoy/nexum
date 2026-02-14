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
        assert_equal [ 1, 2 ], result.map(&:entry_position)
        assert result.all? { |entry| entry.txn_entry_count == 2 }

        ledger_transaction = LedgerTransaction.find_by!(tenant_id: @tenant.id, txn_id: txn_id)
        assert_equal 64, ledger_transaction.payload_hash.length
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

    test "raises conflict when txn_id is reused with different payload" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        txn_id = SecureRandom.uuid
        source_id = SecureRandom.uuid

        service.call(
          txn_id: txn_id,
          posted_at: Time.current,
          source_type: "Test",
          source_id: source_id,
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("50.00") },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("50.00") }
          ]
        )

        error = assert_raises(Ledger::PostTransaction::IdempotencyConflict) do
          service.call(
            txn_id: txn_id,
            posted_at: Time.current,
            source_type: "Test",
            source_id: source_id,
            entries: [
              { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("60.00") },
              { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("60.00") }
            ]
          )
        end

        assert_equal "txn_id_reused_with_different_payload", error.code
        assert_equal 2, LedgerEntry.where(tenant_id: @tenant.id, txn_id: txn_id).count
      end
    end

    test "replays existing settlement source when posted with a different txn_id and same payload" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        source_id = SecureRandom.uuid
        payment_reference = "hospital-payment-post-txn-source-001"
        entries = [
          { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("75.00") },
          { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("75.00") }
        ]

        first = service.call(
          txn_id: SecureRandom.uuid,
          posted_at: Time.current,
          source_type: "ReceivablePaymentSettlement",
          source_id: source_id,
          payment_reference: payment_reference,
          entries: entries
        )

        second = service.call(
          txn_id: SecureRandom.uuid,
          posted_at: Time.current,
          source_type: "ReceivablePaymentSettlement",
          source_id: source_id,
          payment_reference: payment_reference,
          entries: entries
        )

        assert_equal first.map(&:id), second.map(&:id)
        assert_equal 1, LedgerTransaction.where(tenant_id: @tenant.id, source_type: "ReceivablePaymentSettlement", source_id: source_id).count
      end
    end

    test "raises conflict when settlement source is reused with different payload" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        source_id = SecureRandom.uuid
        payment_reference = "hospital-payment-post-txn-source-002"

        service.call(
          txn_id: SecureRandom.uuid,
          posted_at: Time.current,
          source_type: "ReceivablePaymentSettlement",
          source_id: source_id,
          payment_reference: payment_reference,
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("80.00") },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("80.00") }
          ]
        )

        error = assert_raises(Ledger::PostTransaction::IdempotencyConflict) do
          service.call(
            txn_id: SecureRandom.uuid,
            posted_at: Time.current,
            source_type: "ReceivablePaymentSettlement",
            source_id: source_id,
            payment_reference: payment_reference,
            entries: [
              { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("81.00") },
              { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("81.00") }
            ]
          )
        end

        assert_equal "source_reused_with_different_payload", error.code
      end
    end

    test "requires payment_reference for settlement source postings" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        error = assert_raises(Ledger::PostTransaction::ValidationError) do
          service.call(
            txn_id: SecureRandom.uuid,
            posted_at: Time.current,
            source_type: "ReceivablePaymentSettlement",
            source_id: SecureRandom.uuid,
            entries: [
              { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("20.00") },
              { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("20.00") }
            ]
          )
        end

        assert_equal "payment_reference_required", error.code
      end
    end

    test "replays after deterministic unique-collision race on ledger_transaction creation" do
      source_id = SecureRandom.uuid
      payment_reference = "hospital-payment-post-txn-concurrency-001"
      entries = [
        { account_code: "clearing:settlement", entry_side: "DEBIT", amount: BigDecimal("45.00") },
        { account_code: "receivables:hospital", entry_side: "CREDIT", amount: BigDecimal("45.00") }
      ]
      with_tenant_db_context(tenant_id: @tenant.id) do
        first = service.call(
          txn_id: SecureRandom.uuid,
          posted_at: Time.current,
          source_type: "ReceivablePaymentSettlement",
          source_id: source_id,
          payment_reference: payment_reference,
          entries: entries
        )

        collision_raised = false
        singleton = LedgerTransaction.singleton_class
        original_create = LedgerTransaction.method(:create!)
        singleton.send(:define_method, :create!) do |*_, **_kwargs|
          collision_raised = true
          raise ActiveRecord::RecordNotUnique, "simulated race"
        end

        begin
          replayed = service.call(
            txn_id: SecureRandom.uuid,
            posted_at: Time.current,
            source_type: "ReceivablePaymentSettlement",
            source_id: source_id,
            payment_reference: payment_reference,
            entries: entries
          )

          assert_equal first.map(&:id), replayed.map(&:id)
        ensure
          singleton.send(:define_method, :create!, original_create)
        end

        assert collision_raised
        assert_equal 1, LedgerTransaction.where(tenant_id: @tenant.id, source_type: "ReceivablePaymentSettlement", source_id: source_id).count
      end
    end

    test "idempotency ignores only audit_action_log_id metadata" do
      with_tenant_db_context(tenant_id: @tenant.id) do
        txn_id = SecureRandom.uuid
        source_id = SecureRandom.uuid
        entries = [
          {
            account_code: "clearing:settlement",
            entry_side: "DEBIT",
            amount: BigDecimal("12.00"),
            metadata: {
              compensation: {
                reason: "operator_correction",
                audit_action_log_id: "log-1"
              }
            }
          },
          {
            account_code: "receivables:hospital",
            entry_side: "CREDIT",
            amount: BigDecimal("12.00"),
            metadata: {}
          }
        ]

        first = service.call(
          txn_id: txn_id,
          posted_at: Time.current,
          source_type: "ManualCompensation",
          source_id: source_id,
          entries: entries
        )

        replay_entries = entries.deep_dup
        replay_entries.first[:metadata][:compensation][:audit_action_log_id] = "log-2"
        replayed = service.call(
          txn_id: txn_id,
          posted_at: Time.current,
          source_type: "ManualCompensation",
          source_id: source_id,
          entries: replay_entries
        )
        assert_equal first.map(&:id), replayed.map(&:id)

        conflict_entries = entries.deep_dup
        conflict_entries.first[:metadata][:compensation][:reason] = "different_reason"
        error = assert_raises(Ledger::PostTransaction::IdempotencyConflict) do
          service.call(
            txn_id: txn_id,
            posted_at: Time.current,
            source_type: "ManualCompensation",
            source_id: source_id,
            entries: conflict_entries
          )
        end

        assert_equal "txn_id_reused_with_different_payload", error.code
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
