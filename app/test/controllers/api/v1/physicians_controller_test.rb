require "test_helper"

module Api
  module V1
    class PhysiciansControllerTest < ActionDispatch::IntegrationTest
      setup do
        @tenant = tenants(:default)
        @user = users(:one)
        @write_token = nil
        @read_token = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          _, @write_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Physicians Write API",
            scopes: %w[physicians:write]
          )
          _, @read_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Physicians Read API",
            scopes: %w[physicians:read]
          )
        end
      end

      test "creates physician with party profile" do
        post api_v1_physicians_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-physician-create-001"),
          params: {
            physician: {
              full_name: "Dra. Joana Teste",
              email: "joana.teste@example.com",
              phone: "+55 (11) 99999-0001",
              document_number: valid_cpf_from_seed("api-physician-create-001"),
              external_ref: "ext-physician-create-001",
              crm_number: "123456",
              crm_state: "SP",
              metadata: { "source" => "partner_frontend" }
            }
          },
          as: :json

        assert_response :created
        body = response.parsed_body.fetch("data")
        assert_equal false, body["replayed"]
        assert_equal "Dra. Joana Teste", body["full_name"]
        assert_equal "PHYSICIAN_PF", body.dig("party", "kind")
        assert_equal "ext-physician-create-001", body.dig("party", "external_ref")
      end

      test "replays physician creation with same payload" do
        payload = {
          physician: {
            full_name: "Dr. Replay",
            email: "replay@example.com",
            phone: "+55 (11) 99999-0002",
            document_number: valid_cpf_from_seed("api-physician-replay-001"),
            external_ref: "ext-physician-replay-001",
            crm_number: "654321",
            crm_state: "RJ",
            metadata: { "source" => "partner_frontend" }
          }
        }

        post api_v1_physicians_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-physician-replay-001"),
          params: payload,
          as: :json
        assert_response :created

        post api_v1_physicians_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-physician-replay-001"),
          params: payload,
          as: :json
        assert_response :ok
        assert_equal true, response.parsed_body.dig("data", "replayed")
      end

      test "returns conflict when physician payload differs for same unique reference" do
        post api_v1_physicians_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-physician-conflict-001"),
          params: {
            physician: {
              full_name: "Dr. Conflito",
              email: "conflict-1@example.com",
              document_number: valid_cpf_from_seed("api-physician-conflict-001"),
              external_ref: "ext-physician-conflict-001"
            }
          },
          as: :json
        assert_response :created

        post api_v1_physicians_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-physician-conflict-001"),
          params: {
            physician: {
              full_name: "Dr. Conflito Alterado",
              email: "conflict-2@example.com",
              document_number: valid_cpf_from_seed("api-physician-conflict-001"),
              external_ref: "ext-physician-conflict-001"
            }
          },
          as: :json

        assert_response :conflict
        assert_equal "idempotency_key_reused_with_different_payload", response.parsed_body.dig("error", "code")
      end

      test "requires physicians write scope" do
        post api_v1_physicians_path,
          headers: authorization_headers(@read_token, idempotency_key: "idem-physician-scope-001"),
          params: {
            physician: {
              full_name: "Dr. Scope",
              email: "scope@example.com",
              document_number: valid_cpf_from_seed("api-physician-scope-001")
            }
          },
          as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "allows partner application token to create physician" do
        partner_application = nil
        client_secret = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          partner_application, client_secret = PartnerApplication.issue!(
            tenant: @tenant,
            created_by_user: @user,
            name: "Partner Physicians",
            scopes: %w[physicians:write]
          )
        end

        post api_v1_oauth_token_path(tenant_slug: @tenant.slug),
          params: {
            grant_type: "client_credentials",
            client_id: partner_application.client_id,
            client_secret: client_secret,
            scope: "physicians:write"
          }
        assert_response :success
        partner_bearer_token = response.parsed_body.fetch("access_token")

        post api_v1_physicians_path,
          headers: authorization_headers(partner_bearer_token, idempotency_key: "idem-physician-partner-001"),
          params: {
            physician: {
              full_name: "Dr. Partner Flow",
              email: "partner.flow@example.com",
              document_number: valid_cpf_from_seed("api-physician-partner-001")
            }
          },
          as: :json

        assert_response :created
        assert_equal false, response.parsed_body.dig("data", "replayed")
      end

      private

      def authorization_headers(raw_token, idempotency_key: nil)
        headers = { "Authorization" => "Bearer #{raw_token}" }
        headers["Idempotency-Key"] = idempotency_key if idempotency_key.present?
        headers
      end
    end
  end
end
