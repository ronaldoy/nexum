require "test_helper"

module Admin
  class AnticipationRiskRulesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @secondary_tenant = tenants(:secondary)
      @ops_user = users(:one)
      @non_privileged_user = users(:two)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
      end

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @secondary_tenant.update!(active: true)
      end
    end

    test "ops_admin with passkey can view anticipation risk rules page" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_anticipation_risk_rules_path(tenant_id: @secondary_tenant.id)

      assert_response :success
      assert_includes response.body, "Regras de risco de antecipação"
      assert_includes response.body, @secondary_tenant.slug
    end

    test "requires passkey step-up to access anticipation risk rule management" do
      sign_in_as(@ops_user, admin_webauthn_verified: false)

      get admin_anticipation_risk_rules_path

      assert_redirected_to new_admin_passkey_verification_path(return_to: admin_anticipation_risk_rules_path)
    end

    test "non privileged user cannot access anticipation risk rule management" do
      sign_in_as(@non_privileged_user, admin_webauthn_verified: true)

      get admin_anticipation_risk_rules_path

      assert_redirected_to root_path
      follow_redirect!
      assert_includes response.body, "Acesso restrito ao perfil de operação."
    end

    test "creates rule and append-only event for selected tenant" do
      physician_party = nil

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        physician_party = Party.create!(
          tenant: @secondary_tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Médico Regra Admin",
          document_number: valid_cpf_from_seed("admin-risk-rule-physician")
        )
      end

      sign_in_as(@ops_user, admin_webauthn_verified: true)

      post admin_anticipation_risk_rules_path, params: {
        anticipation_risk_rule: {
          tenant_id: @secondary_tenant.id,
          scope_type: "PHYSICIAN_PARTY",
          scope_party_id: physician_party.id,
          decision: "BLOCK",
          priority: 10,
          max_single_request_amount: "500.00"
        }
      }

      assert_redirected_to admin_anticipation_risk_rules_path(tenant_id: @secondary_tenant.id)

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        rule = AnticipationRiskRule.find_by!(tenant_id: @secondary_tenant.id, scope_party_id: physician_party.id)
        assert_equal "BLOCK", rule.decision
        assert_equal 10, rule.priority

        event = AnticipationRiskRuleEvent.find_by!(tenant_id: @secondary_tenant.id, anticipation_risk_rule_id: rule.id, sequence: 1)
        assert_equal "RULE_CREATED", event.event_type

        assert_equal 1, ActionIpLog.where(
          tenant_id: @secondary_tenant.id,
          action_type: "ANTICIPATION_RISK_RULE_CREATED",
          target_id: rule.id
        ).count
      end
    end

    test "updates existing rule and records update event" do
      rule_id = nil

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        rule = AnticipationRiskRule.create!(
          tenant: @secondary_tenant,
          scope_type: "TENANT_DEFAULT",
          decision: "BLOCK",
          priority: 100,
          max_daily_requested_amount: "1000.00"
        )
        rule_id = rule.id
      end

      sign_in_as(@ops_user, admin_webauthn_verified: true)

      patch admin_anticipation_risk_rule_path(rule_id, tenant_id: @secondary_tenant.id), params: {
        anticipation_risk_rule: {
          tenant_id: @secondary_tenant.id,
          decision: "REVIEW",
          priority: 20,
          max_daily_requested_amount: "1500.00",
          max_single_request_amount: "300.00"
        }
      }

      assert_redirected_to admin_anticipation_risk_rules_path(tenant_id: @secondary_tenant.id)

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        rule = AnticipationRiskRule.find(rule_id)
        assert_equal "REVIEW", rule.decision
        assert_equal 20, rule.priority
        assert_equal BigDecimal("1500.00"), rule.max_daily_requested_amount
        assert_equal BigDecimal("300.00"), rule.max_single_request_amount

        event = AnticipationRiskRuleEvent.find_by!(tenant_id: @secondary_tenant.id, anticipation_risk_rule_id: rule.id, sequence: 1)
        assert_equal "RULE_UPDATED", event.event_type
      end
    end

    test "deactivates and activates rule with append-only events" do
      rule_id = nil

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        rule = AnticipationRiskRule.create!(
          tenant: @secondary_tenant,
          scope_type: "TENANT_DEFAULT",
          decision: "BLOCK",
          priority: 100,
          max_outstanding_exposure_amount: "10000.00",
          active: true
        )
        rule_id = rule.id
      end

      sign_in_as(@ops_user, admin_webauthn_verified: true)

      patch deactivate_admin_anticipation_risk_rule_path(rule_id, tenant_id: @secondary_tenant.id)
      assert_redirected_to admin_anticipation_risk_rules_path(tenant_id: @secondary_tenant.id)

      patch activate_admin_anticipation_risk_rule_path(rule_id, tenant_id: @secondary_tenant.id)
      assert_redirected_to admin_anticipation_risk_rules_path(tenant_id: @secondary_tenant.id)

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        rule = AnticipationRiskRule.find(rule_id)
        assert_equal true, rule.active

        events = AnticipationRiskRuleEvent
          .where(tenant_id: @secondary_tenant.id, anticipation_risk_rule_id: rule.id)
          .order(sequence: :asc)

        assert_equal %w[RULE_DEACTIVATED RULE_ACTIVATED], events.pluck(:event_type)
      end
    end
  end
end
