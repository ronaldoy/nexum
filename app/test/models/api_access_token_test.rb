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
        scopes: %w[receivables:read receivables:history]
      )
    end

    authenticated = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      ApiAccessToken.authenticate(raw_token)
    end

    assert_equal token_record.id, authenticated.id
    assert_equal %w[receivables:history receivables:read], token_record.scopes
  end

  test "revoked token cannot authenticate" do
    token_record = nil
    raw_token = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      token_record, raw_token = ApiAccessToken.issue!(tenant: @tenant, user: @user, name: "Revoked Token")
      token_record.revoke!
    end

    authenticated = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      ApiAccessToken.authenticate(raw_token)
    end

    assert_nil authenticated
  end
end
