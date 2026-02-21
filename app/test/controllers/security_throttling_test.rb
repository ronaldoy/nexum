require "test_helper"

class SecurityThrottlingTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @target_email = "target-account@example.com"
    @original_rack_attack_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.cache.store.clear
  end

  teardown do
    Rack::Attack.cache.store = @original_rack_attack_store
  end

  test "throttles login attempts per account across distinct ips" do
    8.times do |index|
      post session_path,
        params: {
          tenant_slug: @user.tenant.slug,
          email_address: @target_email,
          password: "wrong-password"
        },
        env: { "REMOTE_ADDR" => "198.51.100.#{index + 10}" }

      assert_response :redirect
    end

    post session_path,
      params: {
        tenant_slug: @user.tenant.slug,
        email_address: @target_email,
        password: "wrong-password"
      },
      env: { "REMOTE_ADDR" => "203.0.113.20" }

    assert_response :too_many_requests
  end

  test "throttles password reset attempts per account across distinct ips" do
    6.times do |index|
      post passwords_path,
        params: {
          tenant_slug: @user.tenant.slug,
          email_address: @target_email
        },
        env: { "REMOTE_ADDR" => "198.51.100.#{index + 40}" }

      assert_response :redirect
    end

    post passwords_path,
      params: {
        tenant_slug: @user.tenant.slug,
        email_address: @target_email
      },
      env: { "REMOTE_ADDR" => "203.0.113.40" }

    assert_response :too_many_requests
  end

  test "throttles oauth token issuance per client across distinct ips" do
    partner_application = nil

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      partner_application, = PartnerApplication.issue!(
        tenant: @user.tenant,
        created_by_user: @user,
        actor_party: @user.party,
        name: "Throttle OAuth Client",
        scopes: %w[receivables:write]
      )
    end

    20.times do |index|
      post api_v1_oauth_token_path(tenant_slug: @user.tenant.slug),
        headers: { "Idempotency-Key" => "idem-oauth-throttle-#{index}" },
        params: {
          grant_type: "client_credentials",
          client_id: partner_application.client_id,
          client_secret: "invalid-secret",
          scope: "receivables:write"
        },
        env: { "REMOTE_ADDR" => "198.51.100.#{index + 80}" }

      assert_response :unauthorized
    end

    post api_v1_oauth_token_path(tenant_slug: @user.tenant.slug),
      headers: { "Idempotency-Key" => "idem-oauth-throttle-final" },
      params: {
        grant_type: "client_credentials",
        client_id: partner_application.client_id,
        client_secret: "invalid-secret",
        scope: "receivables:write"
      },
      env: { "REMOTE_ADDR" => "203.0.113.88" }

    assert_response :too_many_requests
  end

  test "throttles csp report bursts per ip" do
    120.times do
      post "/security/csp_reports",
        params: { "csp-report" => { "blocked-uri" => "https://example.invalid" } },
        as: :json,
        env: { "REMOTE_ADDR" => "198.51.100.150" }

      assert_includes [ 204, 400 ], response.status
    end

    post "/security/csp_reports",
      params: { "csp-report" => { "blocked-uri" => "https://example.invalid" } },
      as: :json,
      env: { "REMOTE_ADDR" => "198.51.100.150" }

    assert_response :too_many_requests
  end
end
