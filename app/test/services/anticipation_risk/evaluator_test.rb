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
