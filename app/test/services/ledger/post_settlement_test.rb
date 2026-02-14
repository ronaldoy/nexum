require "test_helper"

module Ledger
  class PostSettlementTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @request_id = SecureRandom.uuid
    end

    test "translates shared cnpj settlement into correct ledger entries" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_shared_cnpj_bundle!("ledger-shared-1")
        settlement = create_settlement!(bundle, paid: "100.00", cnpj: "30.00", fdic: "66.00", beneficiary: "4.00")

        result = service.call(
          settlement: settlement,
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          cnpj_amount: BigDecimal("30.00"),
          fdic_amount: BigDecimal("66.00"),
          beneficiary_amount: BigDecimal("4.00"),
          paid_at: Time.current
        )

        assert_equal 8, result.size

        debit_sum = result.select { |e| e.entry_side == "DEBIT" }.sum { |e| e.amount.to_d }
        credit_sum = result.select { |e| e.entry_side == "CREDIT" }.sum { |e| e.amount.to_d }
        assert_equal debit_sum, credit_sum
        assert_equal BigDecimal("200.00"), debit_sum

        # Verify specific account entries
        clearing_debits = result.select { |e| e.account_code == "clearing:settlement" && e.entry_side == "DEBIT" }
        assert_equal 1, clearing_debits.size
        assert_equal BigDecimal("100.00"), clearing_debits.first.amount.to_d

        hospital_credits = result.select { |e| e.account_code == "receivables:hospital" && e.entry_side == "CREDIT" }
        assert_equal 1, hospital_credits.size
        assert_equal BigDecimal("100.00"), hospital_credits.first.amount.to_d

        cnpj_debits = result.select { |e| e.account_code == "obligations:cnpj" && e.entry_side == "DEBIT" }
        assert_equal 1, cnpj_debits.size
        assert_equal BigDecimal("30.00"), cnpj_debits.first.amount.to_d

        fdic_debits = result.select { |e| e.account_code == "obligations:fdic" && e.entry_side == "DEBIT" }
        assert_equal 1, fdic_debits.size
        assert_equal BigDecimal("66.00"), fdic_debits.first.amount.to_d

        beneficiary_debits = result.select { |e| e.account_code == "obligations:beneficiary" && e.entry_side == "DEBIT" }
        assert_equal 1, beneficiary_debits.size
        assert_equal BigDecimal("4.00"), beneficiary_debits.first.amount.to_d
      end
    end

    test "handles supplier with no cnpj leg" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("ledger-supplier-1")
        settlement = create_settlement!(bundle, paid: "100.00", cnpj: "0.00", fdic: "55.00", beneficiary: "45.00")

        result = service.call(
          settlement: settlement,
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          cnpj_amount: BigDecimal("0.00"),
          fdic_amount: BigDecimal("55.00"),
          beneficiary_amount: BigDecimal("45.00"),
          paid_at: Time.current
        )

        # No cnpj entries, so: 2 (clearing/hospital) + 2 (fdic) + 2 (beneficiary) = 6
        assert_equal 6, result.size
        cnpj_entries = result.select { |e| e.account_code == "obligations:cnpj" }
        assert_equal 0, cnpj_entries.size

        debit_sum = result.select { |e| e.entry_side == "DEBIT" }.sum { |e| e.amount.to_d }
        credit_sum = result.select { |e| e.entry_side == "CREDIT" }.sum { |e| e.amount.to_d }
        assert_equal debit_sum, credit_sum
      end
    end

    test "handles no anticipation with no fdic leg" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("ledger-no-antic-1")
        settlement = create_settlement!(bundle, paid: "100.00", cnpj: "0.00", fdic: "0.00", beneficiary: "100.00")

        result = service.call(
          settlement: settlement,
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          cnpj_amount: BigDecimal("0.00"),
          fdic_amount: BigDecimal("0.00"),
          beneficiary_amount: BigDecimal("100.00"),
          paid_at: Time.current
        )

        # 2 (clearing/hospital) + 2 (beneficiary) = 4
        assert_equal 4, result.size
        fdic_entries = result.select { |e| e.account_code == "obligations:fdic" }
        assert_equal 0, fdic_entries.size

        debit_sum = result.select { |e| e.entry_side == "DEBIT" }.sum { |e| e.amount.to_d }
        credit_sum = result.select { |e| e.entry_side == "CREDIT" }.sum { |e| e.amount.to_d }
        assert_equal debit_sum, credit_sum
      end
    end

    test "all entries reference settlement as source" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("ledger-source-ref")
        settlement = create_settlement!(bundle, paid: "100.00", cnpj: "0.00", fdic: "0.00", beneficiary: "100.00")

        result = service.call(
          settlement: settlement,
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          cnpj_amount: BigDecimal("0.00"),
          fdic_amount: BigDecimal("0.00"),
          beneficiary_amount: BigDecimal("100.00"),
          paid_at: Time.current
        )

        assert result.all? { |e| e.source_type == "ReceivablePaymentSettlement" }
        assert result.all? { |e| e.source_id == settlement.id }
        assert result.all? { |e| e.payment_reference == settlement.payment_reference }
      end
    end

    test "all entries share same txn_id" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_shared_cnpj_bundle!("ledger-txn-id")
        settlement = create_settlement!(bundle, paid: "100.00", cnpj: "30.00", fdic: "50.00", beneficiary: "20.00")

        result = service.call(
          settlement: settlement,
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          cnpj_amount: BigDecimal("30.00"),
          fdic_amount: BigDecimal("50.00"),
          beneficiary_amount: BigDecimal("20.00"),
          paid_at: Time.current
        )

        txn_ids = result.map(&:txn_id).uniq
        assert_equal 1, txn_ids.size
      end
    end

    private

    def service
      @service ||= Ledger::PostSettlement.new(tenant_id: @tenant.id, request_id: @request_id)
    end

    def create_shared_cnpj_bundle!(suffix)
      hospital = Party.create!(tenant: @tenant, kind: "HOSPITAL", legal_name: "Hospital #{suffix}", document_number: valid_cnpj_from_seed("#{suffix}-hospital"))
      legal_entity = Party.create!(tenant: @tenant, kind: "LEGAL_ENTITY_PJ", legal_name: "Clinica #{suffix}", document_number: valid_cnpj_from_seed("#{suffix}-legal-entity"))
      physician = Party.create!(tenant: @tenant, kind: "PHYSICIAN_PF", legal_name: "Medico #{suffix}", document_number: valid_cpf_from_seed("#{suffix}-physician"))
      fdic = Party.find_or_create_by!(tenant: @tenant, kind: "FIDC") do |p|
        p.legal_name = "FIDC #{suffix}"
        p.document_number = valid_cnpj_from_seed("#{suffix}-fdic")
      end

      kind = ReceivableKind.create!(tenant: @tenant, code: "physician_shift_#{suffix}", name: "Physician Shift #{suffix}", source_family: "PHYSICIAN")
      receivable = Receivable.create!(
        tenant: @tenant, receivable_kind: kind,
        debtor_party: hospital, creditor_party: legal_entity, beneficiary_party: legal_entity,
        external_reference: "external-#{suffix}", gross_amount: "100.00", currency: "BRL",
        performed_at: Time.current, due_at: 3.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant, receivable: receivable, sequence: 1,
        allocated_party: legal_entity, physician_party: physician,
        gross_amount: "100.00", tax_reserve_amount: "0.00", status: "OPEN"
      )

      { hospital: hospital, legal_entity: legal_entity, physician: physician, fdic: fdic, receivable: receivable, allocation: allocation }
    end

    def create_supplier_bundle!(suffix)
      debtor = Party.create!(tenant: @tenant, kind: "HOSPITAL", legal_name: "Hospital #{suffix}", document_number: valid_cnpj_from_seed("#{suffix}-hospital"))
      supplier = Party.create!(tenant: @tenant, kind: "SUPPLIER", legal_name: "Fornecedor #{suffix}", document_number: valid_cnpj_from_seed("#{suffix}-supplier"))

      kind = ReceivableKind.create!(tenant: @tenant, code: "supplier_invoice_#{suffix}", name: "Supplier Invoice #{suffix}", source_family: "SUPPLIER")
      receivable = Receivable.create!(
        tenant: @tenant, receivable_kind: kind,
        debtor_party: debtor, creditor_party: supplier, beneficiary_party: supplier,
        external_reference: "external-#{suffix}", gross_amount: "100.00", currency: "BRL",
        performed_at: Time.current, due_at: 3.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant, receivable: receivable, sequence: 1,
        allocated_party: supplier, gross_amount: "100.00",
        tax_reserve_amount: "0.00", status: "OPEN"
      )

      { debtor: debtor, supplier: supplier, receivable: receivable, allocation: allocation }
    end

    def create_settlement!(bundle, paid:, cnpj:, fdic:, beneficiary:)
      ReceivablePaymentSettlement.create!(
        tenant: @tenant,
        receivable: bundle[:receivable],
        receivable_allocation: bundle[:allocation],
        paid_amount: paid,
        cnpj_amount: cnpj,
        fdic_amount: fdic,
        beneficiary_amount: beneficiary,
        fdic_balance_before: fdic,
        fdic_balance_after: "0.00",
        paid_at: Time.current,
        payment_reference: "ledger-test-#{SecureRandom.hex(4)}",
        idempotency_key: "ledger-idem-#{SecureRandom.hex(8)}",
        request_id: @request_id,
        metadata: {}
      )
    end
  end
end
