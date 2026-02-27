require "test_helper"

class AnticipationRiskRuleTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @other_tenant = tenants(:secondary)
  end

  test "validates physician scoped risk rule" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      physician_party = Party.create!(
        tenant: @tenant,
        kind: "PHYSICIAN_PF",
        legal_name: "Medico Limite",
        document_number: valid_cpf_from_seed("risk-rule-physician")
      )

      rule = AnticipationRiskRule.new(
        tenant: @tenant,
        scope_type: "PHYSICIAN_PARTY",
        scope_party: physician_party,
        decision: "BLOCK",
        max_single_request_amount: "500.00"
      )

      assert rule.valid?
    end
  end

  test "rejects cnpj scope when party has cpf document type" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      physician_party = Party.create!(
        tenant: @tenant,
        kind: "PHYSICIAN_PF",
        legal_name: "Medico CPF",
        document_number: valid_cpf_from_seed("risk-rule-cnpj-cpf")
      )

      rule = AnticipationRiskRule.new(
        tenant: @tenant,
        scope_type: "CNPJ_PARTY",
        scope_party: physician_party,
        decision: "BLOCK",
        max_daily_requested_amount: "1000.00"
      )

      assert_not rule.valid?
      assert_includes rule.errors[:scope_party], "must have CNPJ document type"
    end
  end

  test "rejects cross-tenant scope party" do
    cross_tenant_party = nil

    with_tenant_db_context(tenant_id: @other_tenant.id) do
      cross_tenant_party = Party.create!(
        tenant: @other_tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital Outro Tenant",
        document_number: valid_cnpj_from_seed("risk-rule-cross-tenant")
      )
    end

    with_tenant_db_context(tenant_id: @tenant.id) do
      rule = AnticipationRiskRule.new(
        tenant: @tenant,
        scope_type: "HOSPITAL_PARTY",
        scope_party: cross_tenant_party,
        decision: "BLOCK",
        max_outstanding_exposure_amount: "1000.00"
      )

      assert_not rule.valid?
      assert_includes rule.errors[:scope_party], "must belong to the same tenant"
    end
  end

  test "enables and forces RLS with tenant policy on anticipation risk rules" do
    connection = ActiveRecord::Base.connection

    rls_row = connection.select_one(<<~SQL)
      SELECT relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE oid = 'anticipation_risk_rules'::regclass
    SQL

    assert_equal true, rls_row["relrowsecurity"]
    assert_equal true, rls_row["relforcerowsecurity"]

    policy = connection.select_one(<<~SQL)
      SELECT policyname, qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'anticipation_risk_rules'
        AND policyname = 'anticipation_risk_rules_tenant_policy'
    SQL

    assert policy.present?
    assert_includes policy["qual"], "tenant_id"
    assert_includes policy["with_check"], "tenant_id"
  end
end
