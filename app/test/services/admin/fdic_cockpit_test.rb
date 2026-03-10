require "test_helper"

module Admin
  class FdicCockpitTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @user = users(:one)
    end

    test "separates open exposure, estimated profit, and realized profit by liquidation state" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "ops_admin") do
        requested_bundle = create_supplier_bundle!("cockpit-requested")
        requested_request = create_anticipation_request!(
          bundle: requested_bundle,
          requested_amount: "120.00",
          discount_amount: "4.80",
          net_amount: "115.20",
          status: "REQUESTED",
          requested_at: Time.zone.parse("2026-02-10 09:30:00")
        )

        partial_bundle = create_supplier_bundle!("cockpit-partial")
        partial_request = create_anticipation_request!(
          bundle: partial_bundle,
          requested_amount: "200.00",
          discount_amount: "8.00",
          net_amount: "192.00",
          status: "FUNDED",
          requested_at: Time.zone.parse("2026-02-10 10:00:00")
        )
        create_settlement_for_request!(
          bundle: partial_bundle,
          anticipation: partial_request,
          settled_amount: "200.00",
          paid_at: Time.zone.parse("2026-02-12 16:00:00")
        )

        full_bundle = create_supplier_bundle!("cockpit-full")
        full_request = create_anticipation_request!(
          bundle: full_bundle,
          requested_amount: "150.00",
          discount_amount: "6.00",
          net_amount: "144.00",
          status: "FUNDED",
          requested_at: Time.zone.parse("2026-02-10 10:30:00")
        )
        create_settlement_for_request!(
          bundle: full_bundle,
          anticipation: full_request,
          settled_amount: "156.00",
          paid_at: Time.zone.parse("2026-02-12 17:00:00")
        )

        cockpit = Admin::FdicCockpit.new(tenant: @tenant)
        requested_row = cockpit.loan_row(requested_request)
        partial_row = cockpit.loan_row(partial_request)
        full_row = cockpit.loan_row(full_request)
        highlights = cockpit.send(:commercial_highlights)
        stage_chart = cockpit.stage_volume_chart.index_by { |stage| stage[:key] }

        assert_equal BigDecimal("0"), requested_row[:open_exposure]
        assert_equal BigDecimal("4.80"), requested_row[:estimated_profit]
        assert_equal BigDecimal("0"), requested_row[:realized_profit]
        assert_equal "Solicitado", requested_row[:current_stage]
        assert_equal false, requested_row[:stages].fetch(:settled)

        assert_equal BigDecimal("8.00"), partial_row[:open_exposure]
        assert_equal BigDecimal("8.00"), partial_row[:estimated_profit]
        assert_equal BigDecimal("0"), partial_row[:realized_profit]
        assert_equal "Liquidação parcial", partial_row[:current_stage]
        assert_equal false, partial_row[:stages].fetch(:settled)

        assert_equal BigDecimal("0"), full_row[:open_exposure]
        assert_equal BigDecimal("0"), full_row[:estimated_profit]
        assert_equal BigDecimal("6.00"), full_row[:realized_profit]
        assert_equal "Liquidado", full_row[:current_stage]
        assert_equal true, full_row[:stages].fetch(:settled)

        assert_equal BigDecimal("8.00"), highlights.fetch(:open_exposure)
        assert_equal BigDecimal("12.80"), highlights.fetch(:estimated_profit)
        assert_equal BigDecimal("6.00"), highlights.fetch(:realized_profit)
        assert_equal 1, highlights.fetch(:fully_liquidated_count)
        assert_equal 2, highlights.fetch(:unsettled_count)
        assert_equal BigDecimal("150.00"), stage_chart.fetch(:settled).fetch(:average_ticket)
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
        gross_amount: "200.00",
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
        gross_amount: receivable.gross_amount,
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )

      { receivable: receivable, allocation: allocation, supplier: supplier }
    end

    def create_anticipation_request!(bundle:, requested_amount:, discount_amount:, net_amount:, status:, requested_at:)
      discount_rate = requested_amount.to_d.zero? ? BigDecimal("0") : (discount_amount.to_d / requested_amount.to_d)

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
      settlement_idempotency = SecureRandom.uuid
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
        paid_at: paid_at,
        payment_reference: settlement_idempotency,
        idempotency_key: settlement_idempotency
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
