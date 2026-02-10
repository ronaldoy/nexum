require "test_helper"

module Fdic
  class ExposureCalculatorTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @user = users(:one)
    end

    test "uses business-day accrual and contractual outstanding for approved anticipation" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_supplier_bundle!("fdic-exp-accrual")
        requested_at = Time.zone.parse("2026-02-10 10:00:00")

        anticipation = create_anticipation_request!(
          bundle: bundle,
          status: "APPROVED",
          requested_amount: "100.00",
          discount_rate: "0.10000000",
          discount_amount: "10.00",
          net_amount: "90.00",
          requested_at: requested_at
        )

        create_settlement_for_request!(
          bundle: bundle,
          anticipation: anticipation,
          settled_amount: "20.00",
          paid_at: Time.zone.parse("2026-02-12 16:00:00")
        )

        metrics = Fdic::ExposureCalculator.new(valuation_time: Time.zone.parse("2026-02-12 18:00:00")).call(
          anticipation_request: anticipation,
          due_at: bundle[:receivable].due_at
        )

        assert_equal true, metrics.exposed
        assert_equal 5, metrics.term_business_days
        assert_equal 2, metrics.elapsed_business_days
        assert_equal BigDecimal("110.00"), metrics.contractual_obligation
        assert_equal BigDecimal("20.00"), metrics.settled_amount
        assert_equal BigDecimal("90.00"), metrics.contractual_outstanding
        assert_equal BigDecimal("4.00"), metrics.accrued_discount
        assert_equal BigDecimal("84.00"), metrics.accrued_outstanding
        assert_equal BigDecimal("90.00"), metrics.effective_contractual_exposure
        assert_equal BigDecimal("84.00"), metrics.effective_accrued_exposure
      end
    end

    test "returns zero effective exposure for non-exposed statuses" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_supplier_bundle!("fdic-exp-requested")

        anticipation = create_anticipation_request!(
          bundle: bundle,
          status: "REQUESTED",
          requested_amount: "80.00",
          discount_rate: "0.10000000",
          discount_amount: "8.00",
          net_amount: "72.00",
          requested_at: Time.zone.parse("2026-02-10 10:00:00")
        )

        metrics = Fdic::ExposureCalculator.new(valuation_time: Time.zone.parse("2026-02-11 11:00:00")).call(
          anticipation_request: anticipation,
          due_at: bundle[:receivable].due_at
        )

        assert_equal false, metrics.exposed
        assert_equal BigDecimal("88.00"), metrics.contractual_outstanding
        assert_equal BigDecimal("0.00"), metrics.effective_contractual_exposure
        assert_equal BigDecimal("0.00"), metrics.effective_accrued_exposure
      end
    end

    private

    def create_supplier_bundle!(suffix)
      hospital = Party.create!(
        tenant: @tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-hospital")
      )
      supplier = Party.create!(
        tenant: @tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-supplier")
      )

      receivable_kind = ReceivableKind.create!(
        tenant: @tenant,
        code: "supplier_invoice_#{suffix}",
        name: "Supplier Invoice #{suffix}",
        source_family: "SUPPLIER"
      )

      receivable = Receivable.create!(
        tenant: @tenant,
        receivable_kind: receivable_kind,
        debtor_party: hospital,
        creditor_party: supplier,
        beneficiary_party: supplier,
        external_reference: "external-#{suffix}",
        gross_amount: "100.00",
        currency: "BRL",
        performed_at: Time.zone.parse("2026-02-10 09:00:00"),
        due_at: Time.zone.parse("2026-02-17 10:00:00"),
        cutoff_at: BusinessCalendar.cutoff_at(Date.new(2026, 2, 10))
      )

      allocation = ReceivableAllocation.create!(
        tenant: @tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: supplier,
        gross_amount: "100.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )

      { receivable: receivable, allocation: allocation, supplier: supplier }
    end

    def create_anticipation_request!(bundle:, status:, requested_amount:, discount_rate:, discount_amount:, net_amount:, requested_at:)
      AnticipationRequest.create!(
        tenant: @tenant,
        receivable: bundle[:receivable],
        receivable_allocation: bundle[:allocation],
        requester_party: bundle[:supplier],
        idempotency_key: SecureRandom.uuid,
        requested_amount: requested_amount,
        discount_rate: discount_rate,
        discount_amount: discount_amount,
        net_amount: net_amount,
        status: status,
        channel: "API",
        requested_at: requested_at,
        settlement_target_date: requested_at.to_date + 1
      )
    end

    def create_settlement_for_request!(bundle:, anticipation:, settled_amount:, paid_at:)
      receivable_settlement = ReceivablePaymentSettlement.create!(
        tenant: @tenant,
        receivable: bundle[:receivable],
        receivable_allocation: bundle[:allocation],
        paid_amount: settled_amount,
        cnpj_amount: "0.00",
        fdic_amount: settled_amount,
        beneficiary_amount: "0.00",
        fdic_balance_before: settled_amount,
        fdic_balance_after: "0.00",
        paid_at: paid_at
      )

      AnticipationSettlementEntry.create!(
        tenant: @tenant,
        receivable_payment_settlement: receivable_settlement,
        anticipation_request: anticipation,
        settled_amount: settled_amount,
        settled_at: paid_at
      )
    end
  end
end
