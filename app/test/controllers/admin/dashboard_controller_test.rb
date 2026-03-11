require "test_helper"
require "digest"

module Admin
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    setup do
      @default_tenant = tenants(:default)
      @ops_user = users(:one)
      @non_privileged_user = users(:two)

      with_tenant_db_context(tenant_id: @default_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
        create_dashboard_sample_data!(tenant: @default_tenant, suffix: "default-admin")
        create_filterable_dashboard_loans!(tenant: @default_tenant)
      end
    end

    test "ops_admin can see fidc cockpit dashboard" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_dashboard_path

      assert_response :success
      assert_includes response.body, "Averta FIDC Manager Cockpit"
      assert_includes response.body, "Gestão diária da carteira performada"
      assert_includes response.body, @default_tenant.slug
      assert_includes response.body, "/chart.umd.min.js"
      assert_includes response.body, "Volume financeiro por estágio"
      assert_includes response.body, "data-controller=\"cockpit-chart\""
      assert_includes response.body, "Pipeline atual"
      assert_includes response.body, "Lucro estimado"
      assert_includes response.body, "Lucro realizado"
      assert_includes response.body, "Rentabilidade registrada"
      assert_includes response.body, "data-controller=\"clickable-row\""
      assert_includes response.body, "Mostrando"
      assert_includes response.body, "risk_manual_review_required_tenant"
      assert_includes response.body, "escrow_webhook_resource_not_found"
    end

    test "non privileged user is redirected away from admin dashboard" do
      sign_in_as(@non_privileged_user)

      get admin_dashboard_path

      assert_redirected_to root_path
      follow_redirect!
      assert_includes response.body, "Acesso restrito ao perfil de gestão FIDC."
    end

    test "ops_admin without passkey step-up is redirected to passkey verification" do
      sign_in_as(@ops_user)

      get admin_dashboard_path

      assert_redirected_to new_admin_passkey_verification_path(return_to: admin_dashboard_path)
      follow_redirect!
      assert_includes response.body, "Validar acesso ao painel administrativo"
    end

    test "ops_admin can access cockpit without passkey with explicit skip flag" do
      sign_in_as(@ops_user)

      with_environment("SKIP_ADMIN_PASSKEY" => "true") do
        get admin_dashboard_path
      end

      assert_response :success
      assert_includes response.body, "Averta FIDC Manager Cockpit"
    end

    test "show seed credentials flag does not bypass admin passkey step-up" do
      sign_in_as(@ops_user)

      with_environment("SHOW_SEED_CREDENTIALS" => "true") do
        get admin_dashboard_path
      end

      assert_redirected_to new_admin_passkey_verification_path(return_to: admin_dashboard_path)
    end

    test "ops_admin can filter dashboard loans by PF and PJ" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_dashboard_path(loan_structure: "pf")

      assert_response :success
      assert_includes response.body, "AVR-FILTER-PF"
      refute_includes response.body, "AVR-FILTER-PJ"
      assert_includes response.body, "loan_structure=pj"

      get admin_dashboard_path(loan_structure: "pj")

      assert_response :success
      assert_includes response.body, "AVR-FILTER-PJ"
      refute_includes response.body, "AVR-FILTER-PF"
      assert_includes response.body, "Médico via PJ"
    end

    test "ops_admin is redirected from root to cockpit" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get root_path

      assert_redirected_to admin_dashboard_path
    end

    test "non privileged user does not see admin shortcut on default dashboard" do
      sign_in_as(@non_privileged_user)

      get root_path

      assert_response :success
      refute_includes response.body, "Averta FIDC Manager Cockpit"
    end

    private

    def with_environment(overrides)
      previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
      overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

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
      pending_review_request = AnticipationRequest.create!(
        tenant: tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        requester_party: supplier,
        idempotency_key: SecureRandom.uuid,
        requested_amount: "80.00",
        discount_rate: "0.04000000",
        discount_amount: "3.20",
        net_amount: "76.80",
        status: "PENDING_REVIEW",
        channel: "API",
        requested_at: Time.zone.parse("2026-02-10 11:00:00"),
        settlement_target_date: Date.new(2026, 2, 11),
        metadata: {
          "pending_review_at" => Time.zone.parse("2026-02-10 11:00:00").utc.iso8601(6),
          "risk_decision_code" => "risk_manual_review_required_tenant"
        }
      )

      settlement_idempotency = SecureRandom.uuid
      settlement = ReceivablePaymentSettlement.create!(
        tenant: tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        paid_amount: "200.00",
        cnpj_amount: "0.00",
        fidc_amount: "200.00",
        beneficiary_amount: "0.00",
        fidc_balance_before: "200.00",
        fidc_balance_after: "0.00",
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

      AnticipationRiskDecision.create!(
        tenant: tenant,
        anticipation_request: pending_review_request,
        receivable: receivable,
        receivable_allocation: allocation,
        requester_party: supplier,
        scope_type: "TENANT_DEFAULT",
        stage: "CREATE",
        decision_action: "REVIEW",
        decision_code: "risk_manual_review_required_tenant",
        decision_metric: "single_request",
        requested_amount: "80.00",
        net_amount: "76.80",
        request_id: SecureRandom.uuid,
        idempotency_key: SecureRandom.uuid,
        evaluated_at: Time.current,
        details: { "limit_value" => "70.00", "observed_value" => "80.00" }
      )

      AnticipationRiskDecision.create!(
        tenant: tenant,
        anticipation_request: anticipation,
        receivable: receivable,
        receivable_allocation: allocation,
        requester_party: supplier,
        scope_type: "TENANT_DEFAULT",
        stage: "CONFIRM",
        decision_action: "BLOCK",
        decision_code: "risk_limit_exceeded_outstanding_exposure_tenant",
        decision_metric: "outstanding_exposure",
        requested_amount: "200.00",
        net_amount: "192.00",
        request_id: SecureRandom.uuid,
        idempotency_key: SecureRandom.uuid,
        evaluated_at: Time.current,
        details: { "limit_value" => "150.00", "observed_value" => "192.00" }
      )
    end

    def create_filterable_dashboard_loans!(tenant:)
      hospital = Party.create!(
        tenant: tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital Filtro",
        document_number: valid_cnpj_from_seed("dashboard-filter-hospital")
      )
      receivable_kind = ReceivableKind.create!(
        tenant: tenant,
        code: "dashboard_filter_physician",
        name: "Plantao medico dashboard",
        source_family: "PHYSICIAN"
      )
      physician = Party.create!(
        tenant: tenant,
        kind: "PHYSICIAN_PF",
        legal_name: "Dra. Elisa Prado",
        display_name: "Dra. Elisa Prado",
        document_number: valid_cpf_from_seed("dashboard-filter-physician")
      )
      legal_entity = Party.create!(
        tenant: tenant,
        kind: "LEGAL_ENTITY_PJ",
        legal_name: "Prado Servicos Medicos Ltda",
        display_name: "Prado Servicos Medicos",
        document_number: valid_cnpj_from_seed("dashboard-filter-pj")
      )

      PhysicianLegalEntityMembership.create!(
        tenant: tenant,
        physician_party: physician,
        legal_entity_party: legal_entity,
        membership_role: "ADMIN",
        status: "ACTIVE",
        joined_at: 30.days.ago
      )

      create_dashboard_loan!(
        tenant: tenant,
        hospital: hospital,
        receivable_kind: receivable_kind,
        external_reference: "AVR-FILTER-PF",
        requester_party: physician,
        allocated_party: physician,
        requested_at: Time.zone.parse("2026-03-08 12:00:00")
      )
      create_dashboard_loan!(
        tenant: tenant,
        hospital: hospital,
        receivable_kind: receivable_kind,
        external_reference: "AVR-FILTER-PJ",
        requester_party: legal_entity,
        allocated_party: legal_entity,
        physician_party: physician,
        requested_at: Time.zone.parse("2026-03-08 12:05:00")
      )
    end

    def create_dashboard_loan!(tenant:, hospital:, receivable_kind:, external_reference:, requester_party:, allocated_party:, requested_at:, physician_party: nil)
      receivable = Receivable.create!(
        tenant: tenant,
        receivable_kind: receivable_kind,
        debtor_party: hospital,
        creditor_party: allocated_party,
        beneficiary_party: allocated_party,
        external_reference: external_reference,
        gross_amount: "1500.00",
        currency: "BRL",
        status: "ANTICIPATION_REQUESTED",
        performed_at: requested_at - 2.hours,
        due_at: requested_at + 45.days,
        cutoff_at: BusinessCalendar.cutoff_at(requested_at.to_date)
      )
      allocation = ReceivableAllocation.create!(
        tenant: tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: allocated_party,
        physician_party: physician_party,
        gross_amount: "1500.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )

      AnticipationRequest.create!(
        tenant: tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        requester_party: requester_party,
        idempotency_key: SecureRandom.uuid,
        requested_amount: "1350.00",
        discount_rate: "0.04500000",
        discount_amount: "60.75",
        net_amount: "1289.25",
        status: "REQUESTED",
        channel: "PORTAL",
        requested_at: requested_at,
        settlement_target_date: requested_at.to_date + 1
      )
    end

    def with_environment(overrides)
      previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
      overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end
end
