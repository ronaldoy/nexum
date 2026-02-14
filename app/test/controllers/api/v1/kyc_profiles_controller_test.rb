require "test_helper"
require "stringio"

module Api
  module V1
    class KycProfilesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @tenant = tenants(:default)
        @secondary_tenant = tenants(:secondary)
        @user = users(:one)

        @write_token = nil
        @read_token = nil
        @no_scope_token = nil
        @party = nil
        @secondary_party = nil
        @kyc_profile = nil
        @secondary_profile = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          @user.update!(role: "ops_admin")
        end

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          _, @write_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "KYC Write API",
            scopes: %w[kyc:write]
          )
          _, @read_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "KYC Read API",
            scopes: %w[kyc:read]
          )
          _, @no_scope_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "No KYC Scope API",
            scopes: %w[receivables:read]
          )

          @party = create_supplier_party!(tenant: @tenant, suffix: "tenant-a")
          @kyc_profile = KycProfile.create!(
            tenant: @tenant,
            party: @party,
            status: "DRAFT",
            risk_level: "UNKNOWN"
          )
        end

        with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @user.id, role: @user.role) do
          @secondary_party = create_supplier_party!(tenant: @secondary_tenant, suffix: "tenant-b")
          @secondary_profile = KycProfile.create!(
            tenant: @secondary_tenant,
            party: @secondary_party,
            status: "DRAFT",
            risk_level: "UNKNOWN"
          )
        end
      end

      test "creates kyc profile with append-only event and action log" do
        party = nil
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          party = create_physician_party!(tenant: @tenant, suffix: "profile-create")
        end

        post api_v1_kyc_profiles_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-profile-create-001"),
          params: {
            kyc_profile: {
              party_id: party.id,
              status: "PENDING_REVIEW",
              risk_level: "LOW",
              metadata: { source: "portal" }
            }
          },
          as: :json

        assert_response :created
        body = response.parsed_body
        assert_equal false, body.dig("data", "replayed")
        assert_equal party.id, body.dig("data", "party_id")
        assert_equal "PENDING_REVIEW", body.dig("data", "status")
        assert_equal "LOW", body.dig("data", "risk_level")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          created_profile = KycProfile.find(body.dig("data", "id"))
          assert_equal 1, KycEvent.where(tenant_id: @tenant.id, kyc_profile_id: created_profile.id, event_type: "KYC_PROFILE_CREATED").count
          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, aggregate_id: created_profile.id, event_type: "KYC_PROFILE_CREATED").count
          assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "KYC_PROFILE_CREATED", target_id: created_profile.id).count
        end
      end

      test "replays kyc profile creation with same idempotency key and payload" do
        party = nil
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          party = create_physician_party!(tenant: @tenant, suffix: "profile-replay")
        end

        payload = {
          kyc_profile: {
            party_id: party.id,
            status: "DRAFT",
            risk_level: "UNKNOWN"
          }
        }

        post api_v1_kyc_profiles_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-profile-replay-001"),
          params: payload,
          as: :json
        assert_response :created
        first_id = response.parsed_body.dig("data", "id")

        post api_v1_kyc_profiles_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-profile-replay-001"),
          params: payload,
          as: :json

        assert_response :ok
        assert_equal true, response.parsed_body.dig("data", "replayed")
        assert_equal first_id, response.parsed_body.dig("data", "id")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, KycProfile.where(tenant_id: @tenant.id, party_id: party.id).count
          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, idempotency_key: "idem-kyc-profile-replay-001").count
          assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "KYC_PROFILE_REPLAYED", target_id: first_id).count
        end
      end

      test "returns conflict when kyc profile idempotency key is reused with different payload" do
        party = nil
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          party = create_physician_party!(tenant: @tenant, suffix: "profile-conflict")
        end

        post api_v1_kyc_profiles_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-profile-conflict-001"),
          params: { kyc_profile: { party_id: party.id, status: "DRAFT", risk_level: "UNKNOWN" } },
          as: :json
        assert_response :created

        post api_v1_kyc_profiles_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-profile-conflict-001"),
          params: { kyc_profile: { party_id: party.id, status: "PENDING_REVIEW", risk_level: "HIGH" } },
          as: :json

        assert_response :conflict
        assert_equal "idempotency_key_reused_with_different_payload", response.parsed_body.dig("error", "code")
      end

      test "returns unprocessable entity when kyc profile already exists and logs failure" do
        post api_v1_kyc_profiles_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-profile-existing-001"),
          params: {
            kyc_profile: {
              party_id: @party.id,
              status: "DRAFT",
              risk_level: "UNKNOWN"
            }
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "kyc_profile_already_exists", response.parsed_body.dig("error", "code")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "KYC_PROFILE_CREATE_FAILED",
            target_id: @party.id
          ).count
        end
      end

      test "submits kyc document with append-only event and action log" do
        blob = create_active_storage_blob(filename: "kyc-rg-001.pdf", content: "kyc rg content")

        post submit_document_api_v1_kyc_profile_path(@kyc_profile.id),
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-doc-submit-001"),
          params: {
            kyc_document: {
              document_type: "RG",
              document_number: "12.345.678-9",
              issuing_country: "BR",
              issuing_state: "SP",
              issued_on: "2020-01-10",
              expires_on: "2030-01-10",
              is_key_document: false,
              blob_signed_id: blob.signed_id,
              sha256: "abc123",
              metadata: { source: "portal_upload" }
            }
          },
          as: :json

        assert_response :created
        body = response.parsed_body
        assert_equal false, body.dig("data", "replayed")
        assert_equal @kyc_profile.id, body.dig("data", "kyc_profile_id")
        assert_equal "RG", body.dig("data", "document_type")
        assert_equal "SP", body.dig("data", "issuing_state")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          document_id = body.dig("data", "id")
          document = KycDocument.find(document_id)
          assert document.file.attached?
          assert_equal blob.id, document.file.blob.id
          assert_equal blob.key, document.storage_key
          assert_equal 1, KycEvent.where(tenant_id: @tenant.id, kyc_profile_id: @kyc_profile.id, event_type: "KYC_DOCUMENT_SUBMITTED").count
          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, event_type: "KYC_DOCUMENT_SUBMITTED", idempotency_key: "idem-kyc-doc-submit-001").count
          assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "KYC_DOCUMENT_SUBMITTED", target_id: document_id).count
        end
      end

      test "replays kyc document submission with same idempotency key and payload" do
        payload = {
          kyc_document: {
            document_type: "CPF",
            document_number: valid_cpf_from_seed("kyc-doc-replay-cpf"),
            issuing_country: "BR",
            is_key_document: true,
            storage_key: "kyc/cpf-001.pdf",
            sha256: "sha-cpf-001"
          }
        }

        post submit_document_api_v1_kyc_profile_path(@kyc_profile.id),
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-doc-replay-001"),
          params: payload,
          as: :json
        assert_response :created
        first_id = response.parsed_body.dig("data", "id")

        post submit_document_api_v1_kyc_profile_path(@kyc_profile.id),
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-doc-replay-001"),
          params: payload,
          as: :json

        assert_response :ok
        assert_equal true, response.parsed_body.dig("data", "replayed")
        assert_equal first_id, response.parsed_body.dig("data", "id")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, KycDocument.where(tenant_id: @tenant.id, id: first_id).count
          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, idempotency_key: "idem-kyc-doc-replay-001").count
          assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "KYC_DOCUMENT_REPLAYED", target_id: first_id).count
        end
      end

      test "returns conflict when kyc document idempotency key is reused with different payload" do
        post submit_document_api_v1_kyc_profile_path(@kyc_profile.id),
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-doc-conflict-001"),
          params: {
            kyc_document: {
              document_type: "RG",
              storage_key: "kyc/rg-conflict-001.pdf",
              sha256: "sha-rg-conflict-001"
            }
          },
          as: :json
        assert_response :created

        post submit_document_api_v1_kyc_profile_path(@kyc_profile.id),
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-doc-conflict-001"),
          params: {
            kyc_document: {
              document_type: "RG",
              storage_key: "kyc/rg-conflict-002.pdf",
              sha256: "sha-rg-conflict-002"
            }
          },
          as: :json

        assert_response :conflict
        assert_equal "idempotency_key_reused_with_different_payload", response.parsed_body.dig("error", "code")
      end

      test "returns unprocessable entity for invalid kyc document payload" do
        post submit_document_api_v1_kyc_profile_path(@kyc_profile.id),
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-doc-invalid-001"),
          params: {
            kyc_document: {
              document_type: "RG",
              is_key_document: true,
              storage_key: "kyc/rg-invalid.pdf",
              sha256: "sha-rg-invalid"
            }
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "invalid_kyc_document", response.parsed_body.dig("error", "code")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "KYC_DOCUMENT_SUBMIT_FAILED", target_id: @kyc_profile.id).count
        end
      end

      test "returns profile details with documents and events" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          KycDocument.create!(
            tenant: @tenant,
            kyc_profile: @kyc_profile,
            party: @party,
            document_type: "CPF",
            document_number: valid_cpf_from_seed("kyc-show-cpf"),
            issuing_country: "BR",
            is_key_document: true,
            storage_key: "kyc/show-cpf.pdf",
            sha256: "sha-show-cpf",
            status: "SUBMITTED"
          )
          KycEvent.create!(
            tenant: @tenant,
            kyc_profile: @kyc_profile,
            party: @party,
            actor_party: @party,
            event_type: "KYC_PROFILE_CREATED",
            occurred_at: Time.current,
            request_id: SecureRandom.uuid,
            payload: {}
          )
        end

        get api_v1_kyc_profile_path(@kyc_profile.id), headers: authorization_headers(@read_token), as: :json

        assert_response :success
        body = response.parsed_body
        assert_equal @kyc_profile.id, body.dig("data", "id")
        assert_equal 1, body.dig("data", "documents").size
        assert_equal 1, body.dig("data", "events").size
      end

      test "requires kyc write scope for write endpoints" do
        post api_v1_kyc_profiles_path,
          headers: authorization_headers(@no_scope_token, idempotency_key: "idem-kyc-scope-001"),
          params: {
            kyc_profile: {
              party_id: @party.id
            }
          },
          as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "requires kyc read scope for show endpoint" do
        get api_v1_kyc_profile_path(@kyc_profile.id), headers: authorization_headers(@write_token), as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "requires idempotency key for write endpoints" do
        post api_v1_kyc_profiles_path,
          headers: authorization_headers(@write_token),
          params: {
            kyc_profile: {
              party_id: @party.id
            }
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "missing_idempotency_key", response.parsed_body.dig("error", "code")
      end

      test "enforces tenant isolation for show and submit document endpoints" do
        get api_v1_kyc_profile_path(@secondary_profile.id), headers: authorization_headers(@read_token), as: :json
        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")

        post submit_document_api_v1_kyc_profile_path(@secondary_profile.id),
          headers: authorization_headers(@write_token, idempotency_key: "idem-kyc-tenant-001"),
          params: {
            kyc_document: {
              document_type: "RG",
              storage_key: "kyc/tenant-iso.pdf",
              sha256: "sha-tenant-iso"
            }
          },
          as: :json
        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")
      end

      private

      def authorization_headers(raw_token, idempotency_key: nil)
        headers = { "Authorization" => "Bearer #{raw_token}" }
        headers["Idempotency-Key"] = idempotency_key if idempotency_key
        headers
      end

      def create_active_storage_blob(filename:, content:)
        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(content),
          filename: filename,
          content_type: "application/pdf"
        )
      end

      def create_supplier_party!(tenant:, suffix:)
        Party.create!(
          tenant: tenant,
          kind: "SUPPLIER",
          legal_name: "Fornecedor #{suffix}",
          document_number: valid_cnpj_from_seed("supplier-#{suffix}")
        )
      end

      def create_physician_party!(tenant:, suffix:)
        Party.create!(
          tenant: tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Medico #{suffix}",
          document_number: valid_cpf_from_seed("physician-#{suffix}")
        )
      end
    end
  end
end
