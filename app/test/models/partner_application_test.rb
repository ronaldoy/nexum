require "test_helper"

class PartnerApplicationTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @ops_user = users(:one)

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
      @ops_user.update!(role: "ops_admin")
    end
  end

  test "requires supported scopes only" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
      application = PartnerApplication.new(
        tenant: @tenant,
        created_by_user: @ops_user,
        name: "Invalid Scope App",
        client_id: SecureRandom.uuid,
        client_secret_digest: PartnerApplication.digest("secret"),
        scopes: [ "receivables:read", "ops:write" ]
      )

      assert_equal false, application.valid?
      assert_includes application.errors[:scopes].join(" "), "unsupported values"
    end
  end

  test "issues scoped access token and tracks token name" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
      application, _secret = PartnerApplication.issue!(
        tenant: @tenant,
        created_by_user: @ops_user,
        name: "Partner App",
        scopes: %w[receivables:read receivables:write]
      )

      assert_equal @ops_user.uuid_id, application.created_by_user_uuid_id

      issued = application.issue_access_token!(requested_scopes: "receivables:read")
      token = issued.fetch(:token)

      assert_equal application.issued_token_name, token.name
      assert_equal [ "receivables:read" ], issued.fetch(:scopes)
      assert issued.fetch(:raw_token).present?
      assert application.reload.last_used_at.present?
    end
  end

  test "rotating secret revokes active tokens for the application" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
      application, _secret = PartnerApplication.issue!(
        tenant: @tenant,
        created_by_user: @ops_user,
        name: "Rotate App",
        scopes: %w[receivables:read]
      )
      issued = application.issue_access_token!
      token = issued.fetch(:token)

      application.rotate_secret!

      assert token.reload.revoked_at.present?
      assert application.reload.rotated_at.present?
    end
  end
end
