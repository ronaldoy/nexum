require "test_helper"

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
  end
end
