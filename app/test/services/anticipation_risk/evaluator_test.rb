require "test_helper"
require "digest"

module AnticipationRisk
  class EvaluatorTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @user = users(:one)
    end

    test "blocks create when cnpj outstanding exposure limit is exceeded" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_cnpj_bundle!(tenant: @tenant, suffix: "risk-evaluator-cnpj")

        AnticipationRequest.create!(
          tenant: @tenant,
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          requester_party: bundle[:legal_entity],
          idempotency_key: "idem-risk-evaluator-existing-001",
          requested_amount: "100.00",
          discount_rate: "0.05000000",
          discount_amount: "5.00",
          net_amount: "95.00",
          status: "REQUESTED",
          channel: "API",
          requested_at: Time.current,
          settlement_target_date: BusinessCalendar.next_business_day(from: Time.current),
          metadata: {}
        )

        AnticipationRiskRule.create!(
          tenant: @tenant,
          scope_type: "CNPJ_PARTY",
          scope_party: bundle[:legal_entity],
          decision: "BLOCK",
          max_outstanding_exposure_amount: "100.00"
        )

        decision = Evaluator.new(tenant_id: @tenant.id).evaluate!(
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          requester_party: bundle[:legal_entity],
          requested_amount: BigDecimal("10.00"),
          net_amount: BigDecimal("10.00"),
          stage: :create
        )

        assert_not decision.allowed?
        assert_equal "risk_limit_exceeded_outstanding_exposure_cnpj", decision.code
        assert_equal "CNPJ_PARTY", decision.scope_type
        assert_equal bundle[:legal_entity].id, decision.scope_party_id
      end
    end

    test "matches cnpj scope across multiple parties with same document number" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_cnpj_bundle!(tenant: @tenant, suffix: "risk-evaluator-cnpj-duplicate")
        mirror_party = Party.create!(
          tenant: @tenant,
          kind: "SUPPLIER",
          legal_name: "Fornecedor Espelho CNPJ",
          document_number: bundle[:legal_entity].document_number
        )

        AnticipationRequest.create!(
          tenant: @tenant,
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          requester_party: mirror_party,
          idempotency_key: "idem-risk-evaluator-cnpj-duplicate-001",
          requested_amount: "100.00",
          discount_rate: "0.05000000",
          discount_amount: "5.00",
          net_amount: "95.00",
          status: "REQUESTED",
          channel: "API",
          requested_at: Time.current,
          settlement_target_date: BusinessCalendar.next_business_day(from: Time.current),
          metadata: {}
        )

        AnticipationRiskRule.create!(
          tenant: @tenant,
          scope_type: "CNPJ_PARTY",
          scope_party: bundle[:legal_entity],
          decision: "BLOCK",
          max_outstanding_exposure_amount: "100.00"
        )

        decision = Evaluator.new(tenant_id: @tenant.id).evaluate!(
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          requester_party: bundle[:legal_entity],
          requested_amount: BigDecimal("10.00"),
          net_amount: BigDecimal("10.00"),
          stage: :create
        )

        assert_not decision.allowed?
        assert_equal "risk_limit_exceeded_outstanding_exposure_cnpj", decision.code
        assert_equal bundle[:legal_entity].id, decision.scope_party_id
      end
    end

    test "acquires advisory locks by tenant, physician, cnpj document and hospital scopes" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_cnpj_bundle!(tenant: @tenant, suffix: "risk-evaluator-lock-keys")
        physician_party = Party.create!(
          tenant: @tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Medico Lock Scope",
          document_number: valid_cpf_from_seed("risk-evaluator-lock-scope-physician")
        )
        bundle[:allocation].update!(physician_party: physician_party)
        AnticipationRiskRule.create!(
          tenant: @tenant,
          scope_type: "TENANT_DEFAULT",
          decision: "BLOCK",
          max_outstanding_exposure_amount: "999999.99"
        )

        evaluator = Evaluator.new(tenant_id: @tenant.id)
        captured_keys = capture_lock_keys(evaluator) do
          evaluator.evaluate!(
            receivable: bundle[:receivable],
            receivable_allocation: bundle[:allocation],
            requester_party: bundle[:legal_entity],
            requested_amount: BigDecimal("10.00"),
            net_amount: BigDecimal("10.00"),
            stage: :create
          )
        end

        expected_keys = [
          "#{@tenant.id}:tenant_default",
          "#{@tenant.id}:physician:#{physician_party.id}",
          "#{@tenant.id}:hospital:#{bundle[:hospital].id}",
          "#{@tenant.id}:cnpj_sha256:#{Digest::SHA256.hexdigest(bundle[:legal_entity].document_number)[0, 16]}"
        ].sort

        assert_equal expected_keys, captured_keys
      end
    end

    test "does not acquire tenant default lock key when no active tenant default rules exist" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_cnpj_bundle!(tenant: @tenant, suffix: "risk-evaluator-lock-no-tenant-default")
        evaluator = Evaluator.new(tenant_id: @tenant.id)

        captured_keys = capture_lock_keys(evaluator) do
          evaluator.evaluate!(
            receivable: bundle[:receivable],
            receivable_allocation: bundle[:allocation],
            requester_party: bundle[:legal_entity],
            requested_amount: BigDecimal("10.00"),
            net_amount: BigDecimal("10.00"),
            stage: :create
          )
        end

        assert captured_keys.none? { |key| key.end_with?(":tenant_default") }
      end
    end

    test "allows request when allow decision rule is exceeded" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_cnpj_bundle!(tenant: @tenant, suffix: "risk-evaluator-allow")

        AnticipationRiskRule.create!(
          tenant: @tenant,
          scope_type: "CNPJ_PARTY",
          scope_party: bundle[:legal_entity],
          decision: "ALLOW",
          max_single_request_amount: "50.00"
        )

        decision = Evaluator.new(tenant_id: @tenant.id).evaluate!(
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          requester_party: bundle[:legal_entity],
          requested_amount: BigDecimal("60.00"),
          net_amount: BigDecimal("60.00"),
          stage: :create
        )

        assert decision.allowed?
        assert_equal "ALLOW", decision.action
        assert_equal "risk_limit_exceeded_single_request_cnpj", decision.code
        assert_match(/override/, decision.message)
        refute_match(/60\.00|50\.00|observed|exceeds/, decision.message)
      end
    end

    test "triggers review when requests per minute limit is exceeded" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_cnpj_bundle!(tenant: @tenant, suffix: "risk-evaluator-rpm-review")
        create_existing_request!(
          tenant: @tenant,
          bundle: bundle,
          requested_amount: "80.00",
          net_amount: "75.00",
          status: "REQUESTED",
          requested_at: Time.current
        )
        AnticipationRiskRule.create!(
          tenant: @tenant,
          scope_type: "TENANT_DEFAULT",
          decision: "REVIEW",
          max_requests_per_minute: 1
        )

        decision = Evaluator.new(tenant_id: @tenant.id).evaluate!(
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          requester_party: bundle[:legal_entity],
          requested_amount: BigDecimal("20.00"),
          net_amount: BigDecimal("19.00"),
          stage: :create
        )

        assert_not decision.allowed?
        assert_equal "REVIEW", decision.action
        assert_equal "risk_manual_review_required_tenant", decision.code
        assert_equal "requests_per_minute", decision.metric
      end
    end

    test "blocks repeated near-limit attempts for requester party" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_cnpj_bundle!(tenant: @tenant, suffix: "risk-evaluator-near-limit")
        2.times do |index|
          AnticipationRiskDecision.create!(
            tenant: @tenant,
            receivable: bundle[:receivable],
            receivable_allocation: bundle[:allocation],
            requester_party: bundle[:legal_entity],
            scope_party: bundle[:legal_entity],
            scope_type: "CNPJ_PARTY",
            stage: "CREATE",
            decision_action: "BLOCK",
            decision_code: "risk_limit_exceeded_single_request_cnpj",
            decision_metric: "single_request",
            requested_amount: "95.00",
            net_amount: "95.00",
            request_id: "risk-near-limit-#{index}",
            idempotency_key: "risk-near-limit-idem-#{index}",
            evaluated_at: 5.minutes.ago
          )
        end

        AnticipationRiskRule.create!(
          tenant: @tenant,
          scope_type: "CNPJ_PARTY",
          scope_party: bundle[:legal_entity],
          decision: "BLOCK",
          max_single_request_amount: "100.00",
          near_limit_attempts_window_minutes: 10,
          near_limit_attempts_max_count: 2,
          near_limit_ratio: "0.900000"
        )

        decision = Evaluator.new(tenant_id: @tenant.id).evaluate!(
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          requester_party: bundle[:legal_entity],
          requested_amount: BigDecimal("95.00"),
          net_amount: BigDecimal("95.00"),
          stage: :create
        )

        assert_not decision.allowed?
        assert_equal "BLOCK", decision.action
        assert_equal "risk_limit_exceeded_near_limit_attempts_cnpj", decision.code
        assert_equal "near_limit_attempts", decision.metric
      end
    end

    test "blocks party-hospital pair spike above historical baseline" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        bundle = create_cnpj_bundle!(tenant: @tenant, suffix: "risk-evaluator-pair-spike")
        local_now = Time.current.in_time_zone(BusinessCalendar.time_zone)
        (1..7).each do |offset_days|
          historical_time = (local_now.to_date - offset_days).to_time.in_time_zone(BusinessCalendar.time_zone).change(hour: 12)
          create_existing_request!(
            tenant: @tenant,
            bundle: bundle,
            requested_amount: "100.00",
            net_amount: "96.00",
            status: "REQUESTED",
            requested_at: historical_time
          )
        end

        AnticipationRiskRule.create!(
          tenant: @tenant,
          scope_type: "CNPJ_PARTY",
          scope_party: bundle[:legal_entity],
          decision: "BLOCK",
          max_single_request_amount: "1000.00",
          pair_spike_multiplier: "2.0000",
          pair_spike_min_daily_amount: "100.00"
        )

        decision = Evaluator.new(tenant_id: @tenant.id).evaluate!(
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          requester_party: bundle[:legal_entity],
          requested_amount: BigDecimal("300.00"),
          net_amount: BigDecimal("290.00"),
          stage: :create
        )

        assert_not decision.allowed?
        assert_equal "BLOCK", decision.action
        assert_equal "risk_limit_exceeded_party_hospital_spike_cnpj", decision.code
        assert_equal "party_hospital_spike", decision.metric
      end
    end

    private

    def create_cnpj_bundle!(tenant:, suffix:)
      hospital = Party.create!(
        tenant: tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-hospital")
      )
      legal_entity = Party.create!(
        tenant: tenant,
        kind: "LEGAL_ENTITY_PJ",
        legal_name: "Clinica #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-legal-entity")
      )

      kind = ReceivableKind.create!(
        tenant: tenant,
        code: "risk_evaluator_#{suffix}",
        name: "Risk Evaluator #{suffix}",
        source_family: "PHYSICIAN"
      )

      receivable = Receivable.create!(
        tenant: tenant,
        receivable_kind: kind,
        debtor_party: hospital,
        creditor_party: legal_entity,
        beneficiary_party: legal_entity,
        external_reference: "risk-evaluator-#{suffix}",
        gross_amount: "200.00",
        currency: "BRL",
        performed_at: Time.current,
        due_at: 3.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
      )

      allocation = ReceivableAllocation.create!(
        tenant: tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: legal_entity,
        gross_amount: "200.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )

      {
        hospital: hospital,
        legal_entity: legal_entity,
        receivable: receivable,
        allocation: allocation
      }
    end

    def create_existing_request!(tenant:, bundle:, requested_amount:, net_amount:, status:, requested_at:)
      AnticipationRequest.create!(
        tenant: tenant,
        receivable: bundle[:receivable],
        receivable_allocation: bundle[:allocation],
        requester_party: bundle[:legal_entity],
        idempotency_key: SecureRandom.uuid,
        requested_amount: requested_amount,
        discount_rate: "0.05000000",
        discount_amount: "5.00",
        net_amount: net_amount,
        status: status,
        channel: "API",
        requested_at: requested_at,
        settlement_target_date: BusinessCalendar.next_business_day(from: requested_at),
        metadata: {}
      )
    end

    def capture_lock_keys(evaluator)
      captured_keys = []
      singleton = class << evaluator
        self
      end

      singleton.send(:alias_method, :advisory_lock_without_capture_for_test, :advisory_lock!)
      singleton.send(:define_method, :advisory_lock!) do |key|
        captured_keys << key
      end

      begin
        yield
      ensure
        singleton.send(:alias_method, :advisory_lock!, :advisory_lock_without_capture_for_test)
        singleton.send(:remove_method, :advisory_lock_without_capture_for_test)
      end

      captured_keys
    end
  end
end
