require "test_helper"

class ApiAccessTokenTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @user = users(:one)
  end

  test "issues and authenticates token" do
    token_record = nil
    raw_token = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      token_record, raw_token = ApiAccessToken.issue!(
        tenant: @tenant,
        user: @user,
        name: "Test Integration",
        scopes: %w[receivables:read receivables:history],
        audit_context: {
          actor_party_id: @user.party_id,
          channel: "API",
          request_id: "token-issue-test-request-id"
        }
      )
    end

    authenticated = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      ApiAccessToken.authenticate(raw_token)
    end

    assert_equal token_record.id, authenticated.id
    assert_equal %w[receivables:history receivables:read], token_record.scopes
    assert_equal @user.uuid_id, token_record.user_uuid_id

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      assert_equal 1, ActionIpLog.where(
        tenant_id: @tenant.id,
        action_type: "API_ACCESS_TOKEN_ISSUED",
        target_type: "ApiAccessToken",
        target_id: token_record.id,
        success: true
      ).count
    end
  end

  test "revoked token cannot authenticate" do
    token_record = nil
    raw_token = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      token_record, raw_token = ApiAccessToken.issue!(tenant: @tenant, user: @user, name: "Revoked Token")
      token_record.revoke!(
        audit_context: {
          actor_party_id: @user.party_id,
          channel: "API",
          request_id: "token-revoke-test-request-id"
        }
      )
    end

    authenticated = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      ApiAccessToken.authenticate(raw_token)
    end

    assert_nil authenticated

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      assert_equal 1, ActionIpLog.where(
        tenant_id: @tenant.id,
        action_type: "API_ACCESS_TOKEN_REVOKED",
        target_type: "ApiAccessToken",
        target_id: token_record.id,
        success: true
      ).count
    end
  end

  test "rejects token when tenant prefix is tampered" do
    raw_token = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      _, raw_token = ApiAccessToken.issue!(tenant: @tenant, user: @user, name: "Tamper Test")
    end

    tampered_token = raw_token.sub(@tenant.id.to_s, tenants(:secondary).id.to_s)

    authenticated = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      ApiAccessToken.authenticate(tampered_token)
    end

    assert_nil authenticated
  end
end
