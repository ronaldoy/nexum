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

  test "normalizes and matches allowed browser origins" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
      application, _secret = PartnerApplication.issue!(
        tenant: @tenant,
        created_by_user: @ops_user,
        actor_party: @ops_user.party,
        name: "Origin Normalize App",
        scopes: %w[receivables:read],
        allowed_origins: [ " https://Frontend.Example.com/ ", "https://frontend.example.com" ]
      )

      assert_equal [ "https://frontend.example.com" ], application.allowed_origins
      assert application.browser_origin_allowed?("https://frontend.example.com")
      refute application.browser_origin_allowed?("https://other.example.com")
    end
  end

  test "rejects invalid allowed browser origins" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
      application = PartnerApplication.new(
        tenant: @tenant,
        created_by_user: @ops_user,
        actor_party: @ops_user.party,
        name: "Invalid Origin App",
        client_id: SecureRandom.uuid,
        client_secret_digest: PartnerApplication.digest("secret"),
        scopes: [ "receivables:read" ],
        allowed_origins: [ "https://frontend.example.com/path", "http://frontend.example.com" ]
      )

      assert_equal false, application.valid?
      assert_includes application.errors[:allowed_origins].join(" "), "invalid HTTPS origins"
    end
  end

  test "issues scoped access token and tracks token name" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
      application, _secret = PartnerApplication.issue!(
        tenant: @tenant,
        created_by_user: @ops_user,
        actor_party: @ops_user.party,
        name: "Partner App",
        scopes: %w[receivables:payment_instructions:read receivables:read receivables:write]
      )

      assert_equal @ops_user.uuid_id, application.created_by_user_uuid_id

      issued = application.issue_access_token!(requested_scopes: "receivables:payment_instructions:read")
      token = issued.fetch(:token)

      assert_equal application.issued_token_name, token.name
      assert_equal [ "receivables:payment_instructions:read" ], issued.fetch(:scopes)
      assert issued.fetch(:raw_token).present?
      assert application.reload.last_used_at.present?
    end
  end

  test "rotating secret revokes active tokens for the application" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
      application, _secret = PartnerApplication.issue!(
        tenant: @tenant,
        created_by_user: @ops_user,
        actor_party: @ops_user.party,
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

  test "does not misattribute token issuance to the application creator" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
      application, _secret = PartnerApplication.issue!(
        tenant: @tenant,
        created_by_user: @ops_user,
        actor_party: @ops_user.party,
        name: "Audit Attribution App",
        scopes: %w[receivables:read]
      )

      application.issue_access_token!(
        audit_context: {
          actor_party_id: nil,
          channel: "API",
          request_id: "partner-token-issue-request-id"
        }
      )

      action_log = ActionIpLog.find_by!(
        tenant_id: @tenant.id,
        action_type: "PARTNER_APPLICATION_TOKEN_ISSUED",
        target_type: "PartnerApplication",
        target_id: application.id,
        request_id: "partner-token-issue-request-id"
      )

      assert_nil action_log.actor_party_id
    end
  end
end
