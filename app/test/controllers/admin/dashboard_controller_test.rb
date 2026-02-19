require "test_helper"
require "digest"

module Admin
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    setup do
      @default_tenant = tenants(:default)
      @secondary_tenant = tenants(:secondary)
      @ops_user = users(:one)
      @non_privileged_user = users(:two)

      with_tenant_db_context(tenant_id: @default_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
        create_dashboard_sample_data!(tenant: @default_tenant, suffix: "default-admin")
      end

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        create_dashboard_sample_data!(tenant: @secondary_tenant, suffix: "secondary-admin")
      end
    end

    test "ops_admin can see global dashboard for all tenants" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_dashboard_path

      assert_response :success
      assert_includes response.body, "Painel administrativo do sistema"
      assert_includes response.body, @default_tenant.slug
      assert_includes response.body, @secondary_tenant.slug
      assert_includes response.body, "Resumo por tenant"
      assert_includes response.body, "Exceções de reconciliação recentes"
      assert_includes response.body, "escrow_webhook_resource_not_found"
    end

    test "non privileged user is redirected away from admin dashboard" do
      sign_in_as(@non_privileged_user)

      get admin_dashboard_path

      assert_redirected_to root_path
      follow_redirect!
      assert_includes response.body, "Acesso restrito ao perfil de operação."
    end

    test "ops_admin without passkey step-up is redirected to passkey verification" do
      sign_in_as(@ops_user)

      get admin_dashboard_path

      assert_redirected_to new_admin_passkey_verification_path(return_to: admin_dashboard_path)
      follow_redirect!
      assert_includes response.body, "Validar acesso ao painel administrativo"
    end

    test "ops_admin sees admin shortcut on default dashboard" do
      sign_in_as(@ops_user)

      get root_path

      assert_response :success
      assert_includes response.body, "Abrir painel admin"
    end

    test "non privileged user does not see admin shortcut on default dashboard" do
      sign_in_as(@non_privileged_user)

      get root_path

      assert_response :success
      refute_includes response.body, "Abrir painel admin"
    end

    private

    def create_dashboard_sample_data!(tenant:, suffix:)
      hospital = Party.create!(
        tenant: tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-hospital")
      )
      organization = Party.create!(
        tenant: tenant,
        kind: "LEGAL_ENTITY_PJ",
        legal_name: "Grupo #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-org")
      )
      supplier = Party.create!(
        tenant: tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-supplier")
      )

      HospitalOwnership.create!(
        tenant: tenant,
        organization_party: organization,
        hospital_party: hospital
      )

      receivable_kind = ReceivableKind.create!(
        tenant: tenant,
        code: "supplier_invoice_#{suffix}",
        name: "Supplier Invoice #{suffix}",
        source_family: "SUPPLIER"
      )
      receivable = Receivable.create!(
        tenant: tenant,
        receivable_kind: receivable_kind,
        debtor_party: hospital,
        creditor_party: supplier,
        beneficiary_party: supplier,
        external_reference: "external-#{suffix}",
        gross_amount: "250.00",
        currency: "BRL",
        status: "PERFORMED",
        performed_at: Time.zone.parse("2026-02-10 09:00:00"),
        due_at: Time.zone.parse("2026-02-20 10:00:00"),
        cutoff_at: BusinessCalendar.cutoff_at(Date.new(2026, 2, 10))
      )
      allocation = ReceivableAllocation.create!(
        tenant: tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: supplier,
        gross_amount: "250.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )
      anticipation = AnticipationRequest.create!(
        tenant: tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        requester_party: supplier,
        idempotency_key: SecureRandom.uuid,
        requested_amount: "200.00",
        discount_rate: "0.04000000",
        discount_amount: "8.00",
        net_amount: "192.00",
        status: "FUNDED",
        channel: "API",
        requested_at: Time.zone.parse("2026-02-10 10:00:00"),
        funded_at: Time.zone.parse("2026-02-10 16:00:00"),
        settlement_target_date: Date.new(2026, 2, 11)
      )

      settlement_idempotency = SecureRandom.uuid
      settlement = ReceivablePaymentSettlement.create!(
        tenant: tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        paid_amount: "200.00",
        cnpj_amount: "0.00",
        fdic_amount: "200.00",
        beneficiary_amount: "0.00",
        fdic_balance_before: "200.00",
        fdic_balance_after: "0.00",
        paid_at: Time.zone.parse("2026-02-12 09:00:00"),
        payment_reference: "pay-#{suffix}",
        idempotency_key: settlement_idempotency
      )
      AnticipationSettlementEntry.create!(
        tenant: tenant,
        receivable_payment_settlement: settlement,
        anticipation_request: anticipation,
        settled_amount: "200.00",
        settled_at: settlement.paid_at
      )

      outbox_event = OutboxEvent.create!(
        tenant: tenant,
        aggregate_type: "Receivable",
        aggregate_id: receivable.id,
        event_type: "RECEIVABLE_CREATED",
        status: "PENDING",
        payload: { "source" => "dashboard-test" }
      )

      if tenant == @secondary_tenant
        OutboxDispatchAttempt.create!(
          tenant: tenant,
          outbox_event: outbox_event,
          attempt_number: 1,
          status: "DEAD_LETTER",
          occurred_at: Time.current,
          error_code: "test_dead_letter"
        )

        ReconciliationException.create!(
          tenant: tenant,
          source: "ESCROW_WEBHOOK",
          provider: "QITECH",
          external_event_id: "evt-dashboard-#{suffix}",
          code: "escrow_webhook_resource_not_found",
          message: "Webhook payload did not match any escrow account or payout.",
          payload_sha256: Digest::SHA256.hexdigest("dashboard-#{suffix}"),
          payload: { "event_id" => "evt-dashboard-#{suffix}" },
          metadata: { "source" => "dashboard_test" },
          status: "OPEN",
          occurrences_count: 1,
          first_seen_at: Time.current,
          last_seen_at: Time.current
        )
      end
    end
  end
end
