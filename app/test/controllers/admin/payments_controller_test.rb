require "test_helper"

module Admin
  class PaymentsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @ops_user = users(:one)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
        create_payments_dashboard_sample_data!
      end
    end

    test "ops admin can view the payments dashboard" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_payments_path

      assert_response :success
      assert_includes response.body, "Painel de pagamentos"
      assert_includes response.body, "Operação Stark Bank"
      assert_includes response.body, @tenant.slug
      assert_includes response.body, "Fila pendente"
      assert_includes response.body, "Lotes de dispatch"
      assert_includes response.body, "Fornecedor Pagamento Pendente"
      assert_includes response.body, "Fornecedor Pagamento Falho"
      assert_includes response.body, "Taxa Stark"
      assert_includes response.body, "R$ 2,50"
      assert_includes response.body, "workspace-default-source"
    end

    test "status filter narrows the payout rows" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_payments_path(status: "failed")

      assert_response :success
      assert_includes response.body, "Fornecedor Pagamento Falho"
      refute_includes response.body, "Fornecedor Pagamento Pendente"
      assert_includes response.body, "status=failed"
      assert_includes response.body, "Exibindo"
    end

    private

    def create_payments_dashboard_sample_data!
      batch = EscrowPayoutBatch.create!(
        tenant: @tenant,
        provider: "STARKBANK",
        status: "OPEN",
        source_provider_account_id: "workspace-default-source",
        risk_limit_amount: "100000.00",
        balance_snapshot_amount: "100000.00",
        reserved_amount: "0.00",
        dispatched_amount: "1250.00",
        fee_amount: "2.50",
        started_at: Time.zone.parse("2026-03-12 10:00:00"),
        last_polled_at: Time.zone.parse("2026-03-12 10:05:00"),
        metadata: {}
      )

      create_payout_record!(
        suffix: "pending",
        party_name: "Fornecedor Pagamento Pendente",
        payout_status: "PENDING",
        provider_status: "created",
        amount: "950.00",
        fee_amount: "0.00",
        batch: batch
      )

      create_payout_record!(
        suffix: "failed",
        party_name: "Fornecedor Pagamento Falho",
        payout_status: "FAILED",
        provider_status: "failed",
        amount: "300.00",
        fee_amount: "2.50",
        batch: batch,
        confirmed_at: nil,
        last_error_code: "starkbank_transfer_failed",
        last_error_message: "Stark Bank PIX transfer failed."
      )
    end

    def create_payout_record!(suffix:, party_name:, payout_status:, provider_status:, amount:, fee_amount:, batch:, confirmed_at: nil, last_error_code: nil, last_error_message: nil)
      hospital = Party.create!(
        tenant: @tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-hospital-payments")
      )
      supplier = Party.create!(
        tenant: @tenant,
        kind: "SUPPLIER",
        legal_name: party_name,
        document_number: valid_cnpj_from_seed("#{suffix}-supplier-payments")
      )
      receivable_kind = ReceivableKind.create!(
        tenant: @tenant,
        code: "supplier_invoice_payments_#{suffix}",
        name: "Supplier Invoice Payments #{suffix}",
        source_family: "SUPPLIER"
      )
      receivable = Receivable.create!(
        tenant: @tenant,
        receivable_kind: receivable_kind,
        debtor_party: hospital,
        creditor_party: supplier,
        beneficiary_party: supplier,
        external_reference: "RCV-PAY-#{suffix.upcase}",
        gross_amount: "1000.00",
        currency: "BRL",
        status: "PERFORMED",
        performed_at: Time.zone.parse("2026-03-10 09:00:00"),
        due_at: 5.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Date.new(2026, 3, 10))
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: supplier,
        gross_amount: "1000.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )
      settlement = ReceivablePaymentSettlement.create!(
        tenant: @tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        paid_amount: "1000.00",
        cnpj_amount: "0.00",
        fidc_amount: "50.00",
        beneficiary_amount: "950.00",
        fidc_balance_before: "50.00",
        fidc_balance_after: "0.00",
        paid_at: Time.zone.parse("2026-03-11 14:00:00"),
        payment_reference: "payment-ref-#{suffix}",
        idempotency_key: "settlement-#{suffix}",
        request_id: SecureRandom.uuid,
        metadata: {}
      )
      escrow_account = EscrowAccount.create!(
        tenant: @tenant,
        party: supplier,
        provider: "STARKBANK",
        account_type: "ESCROW",
        status: "ACTIVE",
        provider_account_id: "workspace-#{suffix}",
        provider_request_id: "workspace-request-#{suffix}",
        last_synced_at: Time.current,
        metadata: {}
      )

      EscrowPayout.create!(
        tenant: @tenant,
        receivable_payment_settlement: settlement,
        party: supplier,
        escrow_account: escrow_account,
        escrow_payout_batch: batch,
        provider: "STARKBANK",
        status: payout_status,
        provider_status: provider_status,
        amount: amount,
        currency: "BRL",
        idempotency_key: "payout-#{suffix}",
        provider_transfer_id: "provider-transfer-#{suffix}",
        provider_fee_amount: fee_amount,
        provider_fee_currency: "BRL",
        provider_source_account_id: batch.source_provider_account_id,
        provider_destination_account_id: escrow_account.provider_account_id,
        requested_at: Time.zone.parse("2026-03-11 14:05:00"),
        processed_at: (payout_status == "FAILED" ? Time.zone.parse("2026-03-11 14:10:00") : nil),
        confirmed_at: confirmed_at,
        last_error_code: last_error_code,
        last_error_message: last_error_message,
        metadata: {}
      )
    end
  end
end
