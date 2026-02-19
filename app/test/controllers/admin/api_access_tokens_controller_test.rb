require "test_helper"

module Admin
  class ApiAccessTokensControllerTest < ActionDispatch::IntegrationTest
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

    test "ops_admin with passkey can view token management page" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_api_access_tokens_path(tenant_id: @secondary_tenant.id)

      assert_response :success
      assert_includes response.body, "Tokens de acesso da API"
      assert_includes response.body, @secondary_tenant.slug
    end

    test "requires passkey step-up to access token management" do
      sign_in_as(@ops_user, admin_webauthn_verified: false)

      get admin_api_access_tokens_path

      assert_redirected_to new_admin_passkey_verification_path(return_to: admin_api_access_tokens_path)
    end

    test "non privileged user cannot access token management" do
      sign_in_as(@non_privileged_user, admin_webauthn_verified: true)

      get admin_api_access_tokens_path

      assert_redirected_to root_path
      follow_redirect!
      assert_includes response.body, "Acesso restrito ao perfil de operação."
    end

    test "creates token for selected tenant and shows raw value once" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      post admin_api_access_tokens_path, params: {
        api_access_token: {
          tenant_id: @secondary_tenant.id,
          name: "Integração ERP",
          scopes_input: "receivables:read,receivables:history",
          user_email: "",
          expires_at: 1.day.from_now.in_time_zone("America/Sao_Paulo").strftime("%Y-%m-%dT%H:%M")
        }
      }

      assert_redirected_to admin_api_access_tokens_path(tenant_id: @secondary_tenant.id)
      follow_redirect!
      assert_response :success
      assert_includes response.body, "Token gerado (exibir uma única vez)"

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        token = ApiAccessToken.where(tenant_id: @secondary_tenant.id, name: "Integração ERP").order(created_at: :desc).first
        assert token.present?
        assert_equal %w[receivables:history receivables:read], token.scopes
      end
    end

    test "revokes token for selected tenant" do
      token_id = nil

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        token, _raw = ApiAccessToken.issue!(
          tenant: @secondary_tenant,
          name: "Token para revogar",
          scopes: %w[receivables:read],
          audit_context: {
            actor_party_id: @ops_user.party_id,
            ip_address: "127.0.0.1",
            user_agent: "test-suite",
            request_id: SecureRandom.uuid,
            endpoint_path: "/setup",
            http_method: "POST",
            channel: "ADMIN"
          }
        )
        token_id = token.id
      end

      sign_in_as(@ops_user, admin_webauthn_verified: true)

      delete admin_api_access_token_path(token_id, tenant_id: @secondary_tenant.id)

      assert_redirected_to admin_api_access_tokens_path(tenant_id: @secondary_tenant.id)

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        token = ApiAccessToken.find(token_id)
        assert token.revoked_at.present?
      end
    end

    test "returns json payload when creating token" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      post admin_api_access_tokens_path(format: :json), params: {
        api_access_token: {
          tenant_id: @tenant.id,
          name: "API JSON Token",
          scopes_input: "receivables:read"
        }
      }

      assert_response :created
      assert response.parsed_body.dig("data", "raw_token").present?
      assert_equal "API JSON Token", response.parsed_body.dig("data", "name")
    end
  end
end
