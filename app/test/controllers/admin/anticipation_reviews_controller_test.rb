require "test_helper"

module Admin
  class AnticipationReviewsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @default_tenant = tenants(:default)
      @secondary_tenant = tenants(:secondary)
      @ops_user = users(:one)
      @non_privileged_user = users(:two)

      with_tenant_db_context(tenant_id: @default_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
      end

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @pending_request = create_pending_review_request!(tenant: @secondary_tenant, suffix: "admin-review-secondary")
      end
    end

    test "ops_admin with passkey can view anticipation review queue" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_anticipation_reviews_path(tenant_id: @secondary_tenant.id)

      assert_response :success
      assert_includes response.body, "Fila de revisão manual de antecipações"
      assert_includes response.body, @pending_request.id
    end

    test "requires passkey step-up to access anticipation review queue" do
      sign_in_as(@ops_user, admin_webauthn_verified: false)

      get admin_anticipation_reviews_path(tenant_id: @secondary_tenant.id)

      assert_redirected_to new_admin_passkey_verification_path(return_to: admin_anticipation_reviews_path(tenant_id: @secondary_tenant.id))
      follow_redirect!
      assert_includes response.body, "Validar acesso ao painel administrativo"
    end

    test "non privileged user cannot access anticipation review queue" do
      sign_in_as(@non_privileged_user, admin_webauthn_verified: true)

      get admin_anticipation_reviews_path(tenant_id: @secondary_tenant.id)

      assert_redirected_to root_path
      follow_redirect!
      assert_includes response.body, "Acesso restrito ao perfil de operação."
    end

    test "approves pending review and moves request back to requested" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      patch approve_admin_anticipation_review_path(@pending_request.id), params: {
        tenant_id: @secondary_tenant.id,
        review_note: "Solicitação aprovada após validação operacional."
      }

      assert_redirected_to admin_anticipation_reviews_path(tenant_id: @secondary_tenant.id)

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @pending_request.reload
        assert_equal "REQUESTED", @pending_request.status
        assert_equal "APPROVED", @pending_request.metadata.fetch("review_decision")
        assert_equal @ops_user.party_id, @pending_request.metadata.fetch("review_decision_by_party_id")

        assert_equal 1, ActionIpLog.where(
          tenant_id: @secondary_tenant.id,
          action_type: "ANTICIPATION_REVIEW_APPROVED",
          target_id: @pending_request.id
        ).count

        assert_equal 1, ReceivableEvent.where(
          tenant_id: @secondary_tenant.id,
          receivable_id: @pending_request.receivable_id,
          event_type: "ANTICIPATION_REVIEW_APPROVED"
        ).count
      end
    end

    test "reject requires note and keeps request pending when absent" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      patch reject_admin_anticipation_review_path(@pending_request.id), params: {
        tenant_id: @secondary_tenant.id,
        review_note: ""
      }

      assert_response :unprocessable_entity
      assert_includes response.body, "Informe o motivo da rejeição."

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @pending_request.reload
        assert_equal "PENDING_REVIEW", @pending_request.status
      end
    end

    test "rejects pending review with mandatory note" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      patch reject_admin_anticipation_review_path(@pending_request.id), params: {
        tenant_id: @secondary_tenant.id,
        review_note: "Inconsistência documental identificada na validação manual."
      }

      assert_redirected_to admin_anticipation_reviews_path(tenant_id: @secondary_tenant.id)

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @pending_request.reload
        assert_equal "REJECTED", @pending_request.status
        assert_equal "REJECTED", @pending_request.metadata.fetch("review_decision")
        assert_equal "Inconsistência documental identificada na validação manual.", @pending_request.metadata.fetch("review_note")

        assert_equal 1, ActionIpLog.where(
          tenant_id: @secondary_tenant.id,
          action_type: "ANTICIPATION_REVIEW_REJECTED",
          target_id: @pending_request.id
        ).count

        assert_equal 1, ReceivableEvent.where(
          tenant_id: @secondary_tenant.id,
          receivable_id: @pending_request.receivable_id,
          event_type: "ANTICIPATION_REVIEW_REJECTED"
        ).count
      end
    end

    private

    def create_pending_review_request!(tenant:, suffix:)
      hospital = Party.create!(
        tenant: tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-hospital")
      )
      supplier = Party.create!(
        tenant: tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-supplier")
      )
      receivable_kind = ReceivableKind.create!(
        tenant: tenant,
        code: "admin_review_#{suffix}",
        name: "Admin review #{suffix}",
        source_family: "SUPPLIER"
      )
      receivable = Receivable.create!(
        tenant: tenant,
        receivable_kind: receivable_kind,
        debtor_party: hospital,
        creditor_party: supplier,
        beneficiary_party: supplier,
        external_reference: "admin-review-receivable-#{suffix}",
        gross_amount: "350.00",
        currency: "BRL",
        status: "PERFORMED",
        performed_at: Time.zone.parse("2026-02-20 09:00:00"),
        due_at: Time.zone.parse("2026-02-25 09:00:00"),
        cutoff_at: BusinessCalendar.cutoff_at(Date.new(2026, 2, 20))
      )
      allocation = ReceivableAllocation.create!(
        tenant: tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: supplier,
        gross_amount: "350.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )

      anticipation_request = AnticipationRequest.create!(
        tenant: tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        requester_party: supplier,
        idempotency_key: SecureRandom.uuid,
        requested_amount: "200.00",
        discount_rate: "0.04000000",
        discount_amount: "8.00",
        net_amount: "192.00",
        status: "PENDING_REVIEW",
        channel: "API",
        requested_at: Time.zone.parse("2026-02-20 10:00:00"),
        settlement_target_date: Date.new(2026, 2, 21),
        metadata: {
          "pending_review_at" => Time.zone.parse("2026-02-20 10:00:00").utc.iso8601(6),
          "risk_decision_code" => "risk_manual_review_required_tenant"
        }
      )

      AnticipationRiskDecision.create!(
        tenant: tenant,
        anticipation_request: anticipation_request,
        receivable: receivable,
        receivable_allocation: allocation,
        requester_party: supplier,
        scope_type: "TENANT_DEFAULT",
        stage: "CREATE",
        decision_action: "REVIEW",
        decision_code: "risk_manual_review_required_tenant",
        decision_metric: "single_request",
        requested_amount: "200.00",
        net_amount: "192.00",
        request_id: SecureRandom.uuid,
        idempotency_key: SecureRandom.uuid,
        evaluated_at: Time.current,
        details: { "limit_value" => "190.00", "observed_value" => "200.00" }
      )

      anticipation_request
    end
  end
end
