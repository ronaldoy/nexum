require "test_helper"
require "base64"

module Api
  module V1
    module Oauth
      class TokensControllerTest < ActionDispatch::IntegrationTest
        setup do
          @tenant = tenants(:default)
          @ops_user = users(:one)
          @partner_application = nil
          @client_secret = nil

          with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
            @partner_application, @client_secret = PartnerApplication.issue!(
              tenant: @tenant,
              created_by_user: @ops_user,
              name: "Portal Parceiro Teste",
              scopes: %w[physicians:write receivables:write anticipation_requests:write]
            )
          end
        end

        test "issues bearer token with client_credentials" do
          post api_v1_oauth_token_path(tenant_slug: @tenant.slug),
            params: {
              grant_type: "client_credentials",
              client_id: @partner_application.client_id,
              client_secret: @client_secret,
              scope: "physicians:write receivables:write"
            }

          assert_response :success
          assert_equal "Bearer", response.parsed_body["token_type"]
          assert response.parsed_body["access_token"].present?
          assert_equal "physicians:write receivables:write", response.parsed_body["scope"]
          assert response.parsed_body["expires_in"].positive?
        end

        test "issues bearer token when client credentials are sent via basic auth" do
          encoded_credentials = Base64.strict_encode64("#{@partner_application.client_id}:#{@client_secret}")

          post api_v1_oauth_token_path(tenant_slug: @tenant.slug),
            headers: { "Authorization" => "Basic #{encoded_credentials}" },
            params: {
              grant_type: "client_credentials",
              scope: "receivables:write"
            }

          assert_response :success
          assert_equal "Bearer", response.parsed_body["token_type"]
          assert response.parsed_body["access_token"].present?
          assert_equal "receivables:write", response.parsed_body["scope"]
        end

        test "rejects invalid client secret" do
          post api_v1_oauth_token_path(tenant_slug: @tenant.slug),
            params: {
              grant_type: "client_credentials",
              client_id: @partner_application.client_id,
              client_secret: "invalid-secret"
            }

          assert_response :unauthorized
          assert_equal "invalid_client", response.parsed_body["error"]
        end

        test "rejects scope outside partner application allowlist" do
          post api_v1_oauth_token_path(tenant_slug: @tenant.slug),
            params: {
              grant_type: "client_credentials",
              client_id: @partner_application.client_id,
              client_secret: @client_secret,
              scope: "ops:write"
            }

          assert_response :bad_request
          assert_equal "invalid_scope", response.parsed_body["error"]
        end

        test "rejects missing client credentials" do
          post api_v1_oauth_token_path(tenant_slug: @tenant.slug),
            params: { grant_type: "client_credentials" }

          assert_response :unauthorized
          assert_equal "invalid_client", response.parsed_body["error"]
        end
      end
    end
  end
end
