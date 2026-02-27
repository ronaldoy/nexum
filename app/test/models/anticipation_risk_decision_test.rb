require "test_helper"

class AnticipationRiskDecisionTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
  end

  test "creates risk decision for create stage" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      bundle = create_receivable_bundle!(tenant: @tenant, suffix: "risk-decision-valid")

      decision = AnticipationRiskDecision.new(
        tenant: @tenant,
        receivable: bundle[:receivable],
        receivable_allocation: bundle[:allocation],
        requester_party: bundle[:beneficiary],
        stage: "CREATE",
        decision_action: "BLOCK",
        decision_code: "risk_limit_exceeded_single_request_hospital",
        requested_amount: "100.00",
        net_amount: "95.00",
        evaluated_at: Time.current,
        details: { "limit_value" => "90.00" }
      )

      assert decision.valid?
    end
  end

  test "enables and forces RLS with tenant policy on anticipation risk decisions" do
    connection = ActiveRecord::Base.connection

    rls_row = connection.select_one(<<~SQL)
      SELECT relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE oid = 'anticipation_risk_decisions'::regclass
    SQL

    assert_equal true, rls_row["relrowsecurity"]
    assert_equal true, rls_row["relforcerowsecurity"]

    policy = connection.select_one(<<~SQL)
      SELECT policyname, qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'anticipation_risk_decisions'
        AND policyname = 'anticipation_risk_decisions_tenant_policy'
    SQL

    assert policy.present?
    assert_includes policy["qual"], "tenant_id"
    assert_includes policy["with_check"], "tenant_id"
  end

  test "append-only trigger blocks UPDATE and DELETE on anticipation risk decisions" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      bundle = create_receivable_bundle!(tenant: @tenant, suffix: "risk-decision-append")
      decision = AnticipationRiskDecision.create!(
        tenant: @tenant,
        receivable: bundle[:receivable],
        receivable_allocation: bundle[:allocation],
        requester_party: bundle[:beneficiary],
        stage: "CREATE",
        decision_action: "ALLOW",
        decision_code: "risk_check_passed",
        requested_amount: "100.00",
        net_amount: "95.00",
        evaluated_at: Time.current,
        details: {}
      )

      update_error = assert_raises(ActiveRecord::StatementInvalid) do
        decision.update!(decision_code: "risk_mutated")
      end
      assert_match(/append-only table/, update_error.message)

      delete_error = assert_raises(ActiveRecord::StatementInvalid) do
        decision.destroy!
      end
      assert_match(/append-only table/, delete_error.message)
    end
  end

  private

  def create_receivable_bundle!(tenant:, suffix:)
    hospital = Party.create!(
      tenant: tenant,
      kind: "HOSPITAL",
      legal_name: "Hospital #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-hospital")
    )
    creditor = Party.create!(
      tenant: tenant,
      kind: "SUPPLIER",
      legal_name: "Credor #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-creditor")
    )
    beneficiary = Party.create!(
      tenant: tenant,
      kind: "SUPPLIER",
      legal_name: "Beneficiario #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-beneficiary")
    )

    kind = ReceivableKind.create!(
      tenant: tenant,
      code: "risk_decision_#{suffix}",
      name: "Risk Decision #{suffix}",
      source_family: "SUPPLIER"
    )

    receivable = Receivable.create!(
      tenant: tenant,
      receivable_kind: kind,
      debtor_party: hospital,
      creditor_party: creditor,
      beneficiary_party: beneficiary,
      external_reference: "risk-decision-#{suffix}",
      gross_amount: "100.00",
      currency: "BRL",
      performed_at: Time.current,
      due_at: 3.days.from_now,
      cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
    )

    allocation = ReceivableAllocation.create!(
      tenant: tenant,
      receivable: receivable,
      sequence: 1,
      allocated_party: beneficiary,
      gross_amount: "100.00",
      tax_reserve_amount: "0.00",
      status: "OPEN"
    )

    {
      receivable: receivable,
      allocation: allocation,
      beneficiary: beneficiary
    }
  end
end
