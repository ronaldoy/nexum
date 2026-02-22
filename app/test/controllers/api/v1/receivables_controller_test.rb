require "test_helper"
require "stringio"

module Api
  module V1
    class ReceivablesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @tenant = tenants(:default)
        @secondary_tenant = tenants(:secondary)
        @user = users(:one)

        @read_token = nil
        @write_token = nil
        @settle_token = nil
        @document_token = nil
        @receivable = nil
        @secondary_receivable = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          @user.update!(role: "ops_admin")
        end

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          _, @read_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Receivables Read API",
            scopes: %w[receivables:read receivables:history]
          )
          _, @write_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Receivables Write API",
            scopes: %w[receivables:write]
          )
          _, @settle_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Receivables Settle API",
            scopes: %w[receivables:settle]
          )
          _, @document_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Receivables Document API",
            scopes: %w[receivables:documents:write]
          )
          @receivable = create_supplier_receivable_bundle_for_tenant!(@tenant, suffix: "tenant-a")[:receivable]
          ReceivableEvent.create!(
            tenant: @tenant,
            receivable: @receivable,
            sequence: 1,
            event_type: "RECEIVABLE_IMPORTED",
            actor_party: @receivable.creditor_party,
            actor_role: "supplier_user",
            occurred_at: Time.current,
            event_hash: SecureRandom.hex(32)
          )
        end

        with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @user.id, role: @user.role) do
          @secondary_receivable = create_supplier_receivable_bundle_for_tenant!(@secondary_tenant, suffix: "tenant-b")[:receivable]
        end
      end

      test "requires bearer token" do
        get api_v1_receivables_path, as: :json

        assert_response :unauthorized
        assert_equal "invalid_token", response.parsed_body.dig("error", "code")
      end

      test "rejects token without bound actor party for receivable listing" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          token_record = ApiAccessToken.authenticate(@read_token)
          token_record.update_columns(user_uuid_id: nil)
        end

        get api_v1_receivables_path, headers: authorization_headers(@read_token), as: :json

        assert_response :forbidden
        assert_equal "actor_party_required", response.parsed_body.dig("error", "code")
      end

      test "lists receivables scoped by tenant context" do
        get api_v1_receivables_path, headers: authorization_headers(@read_token), as: :json

        assert_response :success
        assert_equal 1, response.parsed_body.dig("meta", "count")
        assert_equal @receivable.id, response.parsed_body.dig("data", 0, "id")
        assert_equal "123.45", response.parsed_body.dig("data", 0, "gross_amount")
        @receivable.reload
        provenance = response.parsed_body.dig("data", 0, "provenance")
        assert_equal @receivable.debtor_party.legal_name, provenance.dig("hospital", "legal_name")
        assert_equal @receivable.creditor_party.legal_name, provenance.dig("owning_organization", "legal_name")
      end

      test "allows organization users to manage receivables from owned hospitals" do
        owner_token = nil
        receivable_a = nil
        receivable_b = nil
        receivable_unowned = nil
        hospital_b = nil
        owning_org = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          owning_org = Party.create!(
            tenant: @tenant,
            kind: "LEGAL_ENTITY_PJ",
            legal_name: "Grupo Hospitalar Alpha",
            document_number: valid_cnpj_from_seed("org-owner")
          )
          operational_creditor = Party.create!(
            tenant: @tenant,
            kind: "SUPPLIER",
            legal_name: "Credor Operacional",
            document_number: valid_cnpj_from_seed("org-owner-creditor")
          )
          operational_beneficiary = Party.create!(
            tenant: @tenant,
            kind: "SUPPLIER",
            legal_name: "Beneficiario Operacional",
            document_number: valid_cnpj_from_seed("org-owner-beneficiary")
          )

          hospital_a = Party.create!(
            tenant: @tenant,
            kind: "HOSPITAL",
            legal_name: "Hospital Alpha Unidade A",
            document_number: valid_cnpj_from_seed("org-owner-hospital-a")
          )
          hospital_b = Party.create!(
            tenant: @tenant,
            kind: "HOSPITAL",
            legal_name: "Hospital Alpha Unidade B",
            document_number: valid_cnpj_from_seed("org-owner-hospital-b")
          )
          hospital_unowned = Party.create!(
            tenant: @tenant,
            kind: "HOSPITAL",
            legal_name: "Hospital Sem Vinculo",
            document_number: valid_cnpj_from_seed("org-owner-hospital-unowned")
          )

          HospitalOwnership.create!(
            tenant: @tenant,
            organization_party: owning_org,
            hospital_party: hospital_a
          )
          HospitalOwnership.create!(
            tenant: @tenant,
            organization_party: owning_org,
            hospital_party: hospital_b
          )

          owner_user = User.create!(
            tenant: @tenant,
            party: owning_org,
            email_address: "org-owner-reader@example.com",
            password: "password",
            password_confirmation: "password",
            role: "supplier_user"
          )
          _, owner_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: owner_user,
            name: "Owned Hospitals Reader",
            scopes: %w[receivables:read]
          )

          receivable_a = create_receivable_for_hospital!(
            tenant: @tenant,
            suffix: "owned-hospital-a",
            hospital: hospital_a,
            creditor: operational_creditor,
            beneficiary: operational_beneficiary
          )
          receivable_b = create_receivable_for_hospital!(
            tenant: @tenant,
            suffix: "owned-hospital-b",
            hospital: hospital_b,
            creditor: operational_creditor,
            beneficiary: operational_beneficiary
          )
          receivable_unowned = create_receivable_for_hospital!(
            tenant: @tenant,
            suffix: "unowned-hospital",
            hospital: hospital_unowned,
            creditor: operational_creditor,
            beneficiary: operational_beneficiary
          )
        end

        get api_v1_receivables_path, headers: authorization_headers(owner_token), as: :json

        assert_response :success
        returned_ids = response.parsed_body.fetch("data").map { |entry| entry.fetch("id") }
        assert_includes returned_ids, receivable_a.id
        assert_includes returned_ids, receivable_b.id
        refute_includes returned_ids, receivable_unowned.id

        payload_by_receivable_id = response.parsed_body.fetch("data").index_by { |entry| entry.fetch("id") }
        assert_equal owning_org.legal_name, payload_by_receivable_id.fetch(receivable_a.id).dig("provenance", "owning_organization", "legal_name")
        assert_equal owning_org.legal_name, payload_by_receivable_id.fetch(receivable_b.id).dig("provenance", "owning_organization", "legal_name")

        get api_v1_receivables_path,
          params: { hospital_party_id: hospital_b.id },
          headers: authorization_headers(owner_token),
          as: :json

        assert_response :success
        assert_equal 1, response.parsed_body.dig("meta", "count")
        assert_equal receivable_b.id, response.parsed_body.dig("data", 0, "id")
      end

      test "creates receivable and primary allocation with idempotency replay" do
        payload = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          hospital = Party.create!(
            tenant: @tenant,
            kind: "HOSPITAL",
            legal_name: "Hospital API Create",
            document_number: valid_cnpj_from_seed("api-create-hospital")
          )
          supplier = Party.create!(
            tenant: @tenant,
            kind: "SUPPLIER",
            legal_name: "Supplier API Create",
            document_number: valid_cnpj_from_seed("api-create-supplier")
          )
          beneficiary = Party.create!(
            tenant: @tenant,
            kind: "SUPPLIER",
            legal_name: "Beneficiary API Create",
            document_number: valid_cnpj_from_seed("api-create-beneficiary")
          )
          kind = ReceivableKind.create!(
            tenant: @tenant,
            code: "supplier_invoice_api_create",
            name: "Supplier API Create",
            source_family: "SUPPLIER"
          )

          payload = {
            receivable: {
              external_reference: "external-api-create-001",
              receivable_kind_code: kind.code,
              debtor_party_id: hospital.id,
              creditor_party_id: supplier.id,
              beneficiary_party_id: beneficiary.id,
              gross_amount: "150.00",
              currency: "BRL",
              due_at: 5.days.from_now.iso8601,
              allocation: {
                allocated_party_id: beneficiary.id,
                gross_amount: "150.00",
                tax_reserve_amount: "10.00",
                eligible_for_anticipation: true
              }
            }
          }
        end

        post api_v1_receivables_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-receivable-create-001"),
          params: payload,
          as: :json

        assert_response :created
        body = response.parsed_body.fetch("data")
        receivable_id = body.fetch("id")
        assert_equal false, body.fetch("replayed")
        assert body.fetch("receivable_allocation_id").present?
        assert_equal "150.0", body.fetch("gross_amount")

        post api_v1_receivables_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-receivable-create-001"),
          params: payload,
          as: :json

        assert_response :ok
        assert_equal true, response.parsed_body.dig("data", "replayed")
        assert_equal receivable_id, response.parsed_body.dig("data", "id")
      end

      test "allows partner application token to create receivable" do
        partner_application = nil
        client_secret = nil
        payload = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          hospital = Party.create!(
            tenant: @tenant,
            kind: "HOSPITAL",
            legal_name: "Hospital Partner Receivable",
            document_number: valid_cnpj_from_seed("api-partner-receivable-hospital")
          )
          supplier = Party.create!(
            tenant: @tenant,
            kind: "SUPPLIER",
            legal_name: "Supplier Partner Receivable",
            document_number: valid_cnpj_from_seed("api-partner-receivable-supplier")
          )
          kind = ReceivableKind.create!(
            tenant: @tenant,
            code: "supplier_invoice_partner_create",
            name: "Supplier Partner Create",
            source_family: "SUPPLIER"
          )

          partner_application, client_secret = PartnerApplication.issue!(
            tenant: @tenant,
            created_by_user: @user,
            actor_party: supplier,
            name: "Partner Receivables",
            scopes: %w[receivables:write]
          )

          payload = {
            receivable: {
              external_reference: "external-partner-create-001",
              receivable_kind_code: kind.code,
              debtor_party_id: hospital.id,
              creditor_party_id: supplier.id,
              beneficiary_party_id: supplier.id,
              gross_amount: "80.00",
              currency: "BRL",
              due_at: 5.days.from_now.iso8601
            }
          }
        end

        post api_v1_oauth_token_path(tenant_slug: @tenant.slug),
          headers: { "Idempotency-Key" => "idem-oauth-partner-receivable-001" },
          params: {
            grant_type: "client_credentials",
            client_id: partner_application.client_id,
            client_secret: client_secret,
            scope: "receivables:write"
          }
        assert_response :success
        partner_bearer_token = response.parsed_body.fetch("access_token")

        post api_v1_receivables_path,
          headers: authorization_headers(partner_bearer_token, idempotency_key: "idem-partner-receivable-create-001"),
          params: payload,
          as: :json

        assert_response :created
        assert_equal false, response.parsed_body.dig("data", "replayed")
        assert_equal "external-partner-create-001", response.parsed_body.dig("data", "external_reference")
      end

      test "returns conflict when receivable payload differs for existing external reference" do
        payload = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          hospital = Party.create!(
            tenant: @tenant,
            kind: "HOSPITAL",
            legal_name: "Hospital API Conflict",
            document_number: valid_cnpj_from_seed("api-conflict-hospital")
          )
          supplier = Party.create!(
            tenant: @tenant,
            kind: "SUPPLIER",
            legal_name: "Supplier API Conflict",
            document_number: valid_cnpj_from_seed("api-conflict-supplier")
          )
          kind = ReceivableKind.create!(
            tenant: @tenant,
            code: "supplier_invoice_api_conflict",
            name: "Supplier API Conflict",
            source_family: "SUPPLIER"
          )

          payload = {
            receivable: {
              external_reference: "external-api-conflict-001",
              receivable_kind_code: kind.code,
              debtor_party_id: hospital.id,
              creditor_party_id: supplier.id,
              beneficiary_party_id: supplier.id,
              gross_amount: "200.00",
              currency: "BRL",
              due_at: 5.days.from_now.iso8601
            }
          }
        end

        post api_v1_receivables_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-receivable-conflict-001"),
          params: payload,
          as: :json
        assert_response :created

        payload[:receivable][:gross_amount] = "250.00"
        post api_v1_receivables_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-receivable-conflict-001"),
          params: payload,
          as: :json

        assert_response :conflict
        assert_equal "idempotency_key_reused_with_different_payload", response.parsed_body.dig("error", "code")
      end

      test "requires write scope for receivable creation" do
        post api_v1_receivables_path,
          headers: authorization_headers(@read_token, idempotency_key: "idem-receivable-scope-001"),
          params: {
            receivable: {
              external_reference: "scope-blocked-001",
              gross_amount: "100.00"
            }
          },
          as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "rejects non-string gross amount payload for creation" do
        post api_v1_receivables_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-receivable-type-001"),
          params: {
            receivable: {
              external_reference: "type-receivable-001",
              receivable_kind_code: "missing",
              debtor_party_id: SecureRandom.uuid,
              creditor_party_id: SecureRandom.uuid,
              beneficiary_party_id: SecureRandom.uuid,
              gross_amount: 100.0,
              due_at: 5.days.from_now.iso8601
            }
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "invalid_gross_amount_type", response.parsed_body.dig("error", "code")
      end

      test "returns append-only history timeline" do
        get history_api_v1_receivable_path(@receivable), headers: authorization_headers(@read_token), as: :json

        assert_response :success
        assert_equal @receivable.id, response.parsed_body.dig("data", "receivable", "id")
        assert_equal "RECEIVABLE_IMPORTED", response.parsed_body.dig("data", "events", 0, "event_type")
      end

      test "denies receivable access for non-privileged actor outside party scope" do
        restricted_token = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          restricted_party = Party.create!(
            tenant: @tenant,
            kind: "SUPPLIER",
            legal_name: "Restrito",
            document_number: valid_cnpj_from_seed("restricted-party")
          )
          restricted_user = User.create!(
            tenant: @tenant,
            party: restricted_party,
            email_address: "restricted@example.com",
            password: "password",
            password_confirmation: "password",
            role: "supplier_user"
          )
          _, restricted_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: restricted_user,
            name: "Restricted Receivable Reader",
            scopes: %w[receivables:read]
          )
        end

        get api_v1_receivable_path(@receivable.id), headers: authorization_headers(restricted_token), as: :json

        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")
      end

      test "attaches signed document metadata to receivable" do
        signed_at = Time.current
        blob_content = "signed contract binary"
        blob = create_active_storage_blob(filename: "assignment-contract-001.pdf", content: blob_content)
        challenges = create_document_signature_challenges!(
          receivable: @receivable,
          actor_party: @receivable.creditor_party,
          suffix: "attach-001"
        )

        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-attach-001"),
          params: {
            document: {
              actor_party_id: @receivable.creditor_party_id,
              document_type: "assignment_contract",
              sha256: Digest::SHA256.hexdigest(blob_content),
              blob_signed_id: blob.signed_id,
              signed_at: signed_at.iso8601,
              provider_envelope_id: "env-doc-001",
              email_challenge_id: challenges[:email].id,
              whatsapp_challenge_id: challenges[:whatsapp].id,
              metadata: { source: "signature_provider" }
            }
          },
          as: :json

        assert_response :created
        body = response.parsed_body
        document_id = body.dig("data", "id")
        assert_equal false, body.dig("data", "replayed")
        assert_equal @receivable.id, body.dig("data", "receivable_id")
        assert_equal @receivable.creditor_party_id, body.dig("data", "actor_party_id")
        assert_equal "ASSIGNMENT_CONTRACT", body.dig("data", "document_type")
        assert_equal "SIGNED", body.dig("data", "status")
        assert_equal Digest::SHA256.hexdigest(blob_content), body.dig("data", "sha256")
        assert_equal "env-doc-001", body.dig("data", "metadata", "provider_envelope_id")
        assert_equal 1, body.dig("data", "events").size

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          document = Document.find(document_id)
          assert_equal blob.key, document.storage_key
          assert document.file.attached?
          assert_equal blob.id, document.file.blob.id
          assert_equal 1, DocumentEvent.where(tenant_id: @tenant.id, document_id: document_id, event_type: "DOCUMENT_SIGNED_METADATA_ATTACHED").count
          assert_equal 1, ReceivableEvent.where(tenant_id: @tenant.id, receivable_id: @receivable.id, event_type: "RECEIVABLE_DOCUMENT_ATTACHED").count
          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, event_type: "RECEIVABLE_DOCUMENT_ATTACHED", idempotency_key: "idem-document-attach-001").count
          assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "RECEIVABLE_DOCUMENT_ATTACHED", target_id: document_id).count

          refreshed_email_challenge = AuthChallenge.find(challenges[:email].id)
          refreshed_whatsapp_challenge = AuthChallenge.find(challenges[:whatsapp].id)
          assert_equal "CANCELLED", refreshed_email_challenge.status
          assert_equal "CANCELLED", refreshed_whatsapp_challenge.status
          assert refreshed_email_challenge.consumed_at.present?
          assert refreshed_whatsapp_challenge.consumed_at.present?
        end
      end

      test "filters sensitive metadata when attaching signed documents" do
        signed_at = Time.current
        blob_content = "signed contract metadata filter"
        blob = create_active_storage_blob(filename: "assignment-contract-metadata.pdf", content: blob_content)
        challenges = create_document_signature_challenges!(
          receivable: @receivable,
          actor_party: @receivable.creditor_party,
          suffix: "attach-meta-001"
        )

        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-attach-meta-001"),
          params: {
            document: {
              actor_party_id: @receivable.creditor_party_id,
              document_type: "assignment_contract",
              sha256: Digest::SHA256.hexdigest(blob_content),
              blob_signed_id: blob.signed_id,
              signed_at: signed_at.iso8601,
              provider_envelope_id: "env-doc-meta-001",
              email_challenge_id: challenges[:email].id,
              whatsapp_challenge_id: challenges[:whatsapp].id,
              metadata: {
                source: "signature_provider",
                source_reference: "erp-contract-001",
                cpf: "123.456.789-09",
                contact_email: "document@example.com",
                freeform: "custom-untrusted-value"
              }
            }
          },
          as: :json

        assert_response :created
        metadata = response.parsed_body.dig("data", "metadata")
        assert_equal "signature_provider", metadata["source"]
        assert_equal "erp-contract-001", metadata["source_reference"]
        assert_equal "env-doc-meta-001", metadata["provider_envelope_id"]
        refute metadata.key?("cpf")
        refute metadata.key?("contact_email")
        refute metadata.key?("freeform")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          persisted = Document.find(response.parsed_body.dig("data", "id"))
          assert_equal "signature_provider", persisted.metadata["source"]
          assert_equal "erp-contract-001", persisted.metadata["source_reference"]
          refute persisted.metadata.key?("cpf")
          refute persisted.metadata.key?("contact_email")
          refute persisted.metadata.key?("freeform")
        end
      end

      test "rejects reused signature challenges for a new document attach idempotency key" do
        signed_at = Time.current
        challenges = create_document_signature_challenges!(
          receivable: @receivable,
          actor_party: @receivable.creditor_party,
          suffix: "reuse-001"
        )

        payload = {
          document: {
            actor_party_id: @receivable.creditor_party_id,
            document_type: "assignment_contract",
            sha256: "sha-doc-reuse-001",
            storage_key: "docs/assignment-contract-reuse-001.pdf",
            signed_at: signed_at.iso8601,
            provider_envelope_id: "env-doc-reuse-001",
            email_challenge_id: challenges[:email].id,
            whatsapp_challenge_id: challenges[:whatsapp].id
          }
        }

        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-reuse-001"),
          params: payload,
          as: :json
        assert_response :created

        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-reuse-002"),
          params: payload,
          as: :json

        assert_response :unprocessable_entity
        assert_equal "used_email_challenge", response.parsed_body.dig("error", "code")
      end

      test "replays signed document attach with same idempotency key and payload" do
        challenges = create_document_signature_challenges!(
          receivable: @receivable,
          actor_party: @receivable.creditor_party,
          suffix: "replay-001"
        )
        payload = {
          document: {
            actor_party_id: @receivable.creditor_party_id,
            document_type: "assignment_contract",
            sha256: "sha-doc-replay-001",
            storage_key: "docs/assignment-contract-replay-001.pdf",
            signed_at: Time.current.iso8601,
            provider_envelope_id: "env-doc-replay-001",
            email_challenge_id: challenges[:email].id,
            whatsapp_challenge_id: challenges[:whatsapp].id
          }
        }

        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-replay-001"),
          params: payload,
          as: :json
        assert_response :created
        first_id = response.parsed_body.dig("data", "id")

        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-replay-001"),
          params: payload,
          as: :json

        assert_response :ok
        assert_equal true, response.parsed_body.dig("data", "replayed")
        assert_equal first_id, response.parsed_body.dig("data", "id")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, Document.where(tenant_id: @tenant.id, id: first_id).count
          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, idempotency_key: "idem-document-replay-001").count
          assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "RECEIVABLE_DOCUMENT_REPLAYED", target_id: first_id).count
        end
      end

      test "returns conflict when document idempotency key is reused with different payload" do
        challenges = create_document_signature_challenges!(
          receivable: @receivable,
          actor_party: @receivable.creditor_party,
          suffix: "conflict-001"
        )
        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-conflict-001"),
          params: {
            document: {
              actor_party_id: @receivable.creditor_party_id,
              document_type: "assignment_contract",
              sha256: "sha-doc-conflict-001",
              storage_key: "docs/assignment-contract-conflict-001.pdf",
              signed_at: Time.current.iso8601,
              provider_envelope_id: "env-doc-conflict-001",
              email_challenge_id: challenges[:email].id,
              whatsapp_challenge_id: challenges[:whatsapp].id
            }
          },
          as: :json
        assert_response :created

        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-conflict-001"),
          params: {
            document: {
              actor_party_id: @receivable.creditor_party_id,
              document_type: "assignment_contract",
              sha256: "sha-doc-conflict-002",
              storage_key: "docs/assignment-contract-conflict-002.pdf",
              signed_at: Time.current.iso8601,
              provider_envelope_id: "env-doc-conflict-001",
              email_challenge_id: challenges[:email].id,
              whatsapp_challenge_id: challenges[:whatsapp].id
            }
          },
          as: :json

        assert_response :conflict
        assert_equal "idempotency_key_reused_with_different_payload", response.parsed_body.dig("error", "code")
      end

      test "returns conflict when attach document replay evidence is missing payload hash" do
        idempotency_key = "idem-document-missing-hash-001"
        signed_at = Time.current
        document = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          document = Document.create!(
            tenant: @tenant,
            receivable: @receivable,
            actor_party: @receivable.creditor_party,
            document_type: "ASSIGNMENT_CONTRACT",
            signature_method: "OWN_PLATFORM_CONFIRMATION",
            status: "SIGNED",
            sha256: "sha-controller-missing-hash",
            storage_key: "docs/controller-missing-hash.pdf",
            signed_at: signed_at,
            metadata: {}
          )
          insert_legacy_outbox_without_payload_hash!(
            tenant_id: @tenant.id,
            aggregate_type: "Receivable",
            aggregate_id: @receivable.id,
            event_type: "RECEIVABLE_DOCUMENT_ATTACHED",
            idempotency_key: idempotency_key,
            payload: {
              "receivable_id" => @receivable.id,
              "document_id" => document.id
            }
          )
        end

        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: idempotency_key),
          params: {
            document: {
              actor_party_id: @receivable.creditor_party_id,
              document_type: "assignment_contract",
              sha256: "sha-controller-input-missing-hash",
              storage_key: "docs/controller-input-missing-hash.pdf",
              signed_at: signed_at.iso8601,
              provider_envelope_id: "env-controller-missing-hash",
              email_challenge_id: SecureRandom.uuid,
              whatsapp_challenge_id: SecureRandom.uuid
            }
          },
          as: :json

        assert_response :conflict
        assert_equal "idempotency_key_reused_without_payload_hash", response.parsed_body.dig("error", "code")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, Document.where(tenant_id: @tenant.id, id: document.id).count
        end
      end

      test "returns unprocessable entity for invalid attach document payload and logs failure" do
        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-invalid-001"),
          params: {
            document: {
              actor_party_id: @receivable.creditor_party_id,
              document_type: "assignment_contract",
              sha256: "sha-doc-invalid-001",
              storage_key: "docs/assignment-contract-invalid-001.pdf",
              provider_envelope_id: "env-doc-invalid-001",
              email_challenge_id: "challenge-email-invalid-001",
              whatsapp_challenge_id: "challenge-whatsapp-invalid-001"
            }
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "invalid_signed_at", response.parsed_body.dig("error", "code")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "RECEIVABLE_DOCUMENT_ATTACH_FAILED",
            target_id: @receivable.id
          ).count
        end
      end

      test "settles shared cnpj receivable payment and returns cnpj, fdic and physician split" do
        bundle = nil
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          bundle = create_shared_cnpj_physician_bundle_for_tenant!(@tenant, suffix: "settlement-cnpj")
          create_direct_anticipation_request!(
            tenant: @tenant,
            receivable: bundle[:receivable],
            allocation: bundle[:allocation],
            requester_party: bundle[:physician_one],
            idempotency_key: "idem-settlement-cnpj-anticipation",
            requested_amount: "60.00",
            discount_rate: "0.10000000",
            discount_amount: "6.00",
            net_amount: "54.00",
            status: "APPROVED"
          )
        end

        post settle_payment_api_v1_receivable_path(bundle[:receivable].id),
          headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-api-001"),
          params: {
            settlement: {
              receivable_allocation_id: bundle[:allocation].id,
              paid_amount: "100.00",
              paid_at: Time.current.iso8601,
              metadata: { source: "hospital_erp" }
            }
          },
          as: :json

        assert_response :created
        body = response.parsed_body
        assert_equal false, body.dig("data", "replayed")
        assert_equal "30.0", body.dig("data", "cnpj_amount")
        assert_equal "66.0", body.dig("data", "fdic_amount")
        assert_equal "4.0", body.dig("data", "physician_amount")
        assert_equal 1, body.dig("data", "settlement_entries").size
      end

      test "replays settlement with same idempotency key and payload" do
        bundle = nil
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          bundle = create_shared_cnpj_physician_bundle_for_tenant!(@tenant, suffix: "settlement-replay")
        end

        payload = {
          settlement: {
            receivable_allocation_id: bundle[:allocation].id,
            paid_amount: "100.00",
            paid_at: Time.current.iso8601
          }
        }

        post settle_payment_api_v1_receivable_path(bundle[:receivable].id),
          headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-api-replay-001"),
          params: payload,
          as: :json
        assert_response :created
        first_id = response.parsed_body.dig("data", "id")

        post settle_payment_api_v1_receivable_path(bundle[:receivable].id),
          headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-api-replay-001"),
          params: payload,
          as: :json

        assert_response :ok
        assert_equal true, response.parsed_body.dig("data", "replayed")
        assert_equal first_id, response.parsed_body.dig("data", "id")
      end

      test "requires settle scope for settlement endpoint" do
        post settle_payment_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@read_token, idempotency_key: "idem-settle-scope-001"),
          params: { settlement: { paid_amount: "100.00" } },
          as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "requires document scope for attach document endpoint" do
        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@read_token, idempotency_key: "idem-document-scope-001"),
          params: {
            document: {
              actor_party_id: @receivable.creditor_party_id,
              document_type: "assignment_contract",
              sha256: "sha-doc-scope-001",
              storage_key: "docs/assignment-contract-scope-001.pdf",
              signed_at: Time.current.iso8601,
              provider_envelope_id: "env-doc-scope-001",
              email_challenge_id: "challenge-email-scope-001",
              whatsapp_challenge_id: "challenge-whatsapp-scope-001"
            }
          },
          as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "requires idempotency key header for settlement endpoint" do
        post settle_payment_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@settle_token),
          params: { settlement: { paid_amount: "100.00" } },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "missing_idempotency_key", response.parsed_body.dig("error", "code")
      end

      test "rejects non-string monetary payloads for settlement" do
        post settle_payment_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-type-001"),
          params: { settlement: { paid_amount: 100.00 } },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "invalid_paid_amount_type", response.parsed_body.dig("error", "code")
      end

      test "requires idempotency key header for attach document endpoint" do
        post attach_document_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@document_token),
          params: {
            document: {
              actor_party_id: @receivable.creditor_party_id,
              document_type: "assignment_contract",
              sha256: "sha-doc-idem-001",
              storage_key: "docs/assignment-contract-idem-001.pdf",
              signed_at: Time.current.iso8601,
              provider_envelope_id: "env-doc-idem-001",
              email_challenge_id: "challenge-email-idem-001",
              whatsapp_challenge_id: "challenge-whatsapp-idem-001"
            }
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "missing_idempotency_key", response.parsed_body.dig("error", "code")
      end

      test "enforces tenant isolation for settlement endpoint" do
        post settle_payment_api_v1_receivable_path(@secondary_receivable.id),
          headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-tenant-001"),
          params: { settlement: { paid_amount: "100.00" } },
          as: :json

        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")
      end

      test "enforces tenant isolation for attach document endpoint" do
        post attach_document_api_v1_receivable_path(@secondary_receivable.id),
          headers: authorization_headers(@document_token, idempotency_key: "idem-document-tenant-001"),
          params: {
            document: {
              actor_party_id: @receivable.creditor_party_id,
              document_type: "assignment_contract",
              sha256: "sha-doc-tenant-001",
              storage_key: "docs/assignment-contract-tenant-001.pdf",
              signed_at: Time.current.iso8601,
              provider_envelope_id: "env-doc-tenant-001",
              email_challenge_id: "challenge-email-tenant-001",
              whatsapp_challenge_id: "challenge-whatsapp-tenant-001"
            }
          },
          as: :json

        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")
      end

      test "unexpected settlement DB failures propagate as internal errors" do
        failing_service = Object.new
        failing_service.define_singleton_method(:call) do |**|
          raise ActiveRecord::StatementInvalid, "PG::UndefinedTable: relation does not exist"
        end

        with_stubbed_settlement_service(failing_service) do
          assert_raises(ActiveRecord::StatementInvalid) do
            post settle_payment_api_v1_receivable_path(@receivable.id),
              headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-internal-001"),
              params: { settlement: { paid_amount: "100.00" } },
              as: :json
          end
        end
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
          content_type: "application/pdf",
          metadata: { "tenant_id" => @tenant.id.to_s }
        )
      end

      def create_supplier_receivable_bundle_for_tenant!(tenant, suffix:)
        debtor = Party.create!(
          tenant: tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-hospital")
        )
        creditor = Party.create!(
          tenant: tenant,
          kind: "SUPPLIER",
          legal_name: "Fornecedor #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-supplier-creditor")
        )
        beneficiary = Party.create!(
          tenant: tenant,
          kind: "SUPPLIER",
          legal_name: "Beneficiario #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-supplier-beneficiary")
        )
        kind = ReceivableKind.create!(
          tenant: tenant,
          code: "supplier_invoice_#{suffix}",
          name: "Supplier Invoice #{suffix}",
          source_family: "SUPPLIER"
        )

        receivable = Receivable.create!(
          tenant: tenant,
          receivable_kind: kind,
          debtor_party: debtor,
          creditor_party: creditor,
          beneficiary_party: beneficiary,
          external_reference: "external-#{suffix}",
          gross_amount: "123.45",
          currency: "BRL",
          performed_at: Time.current,
          due_at: 3.days.from_now,
          cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
        )

        allocation = ReceivableAllocation.create!(
          tenant: tenant,
          receivable: receivable,
          sequence: 1,
          allocated_party: beneficiary,
          gross_amount: receivable.gross_amount,
          tax_reserve_amount: "0.00",
          status: "OPEN"
        )

        {
          debtor: debtor,
          creditor: creditor,
          beneficiary: beneficiary,
          receivable: receivable,
          allocation: allocation
        }
      end

      def create_receivable_for_hospital!(tenant:, suffix:, hospital:, creditor:, beneficiary:)
        kind = ReceivableKind.create!(
          tenant: tenant,
          code: "hospital_invoice_#{suffix}",
          name: "Hospital Invoice #{suffix}",
          source_family: "SUPPLIER"
        )

        receivable = Receivable.create!(
          tenant: tenant,
          receivable_kind: kind,
          debtor_party: hospital,
          creditor_party: creditor,
          beneficiary_party: beneficiary,
          external_reference: "external-#{suffix}",
          gross_amount: "180.00",
          currency: "BRL",
          performed_at: Time.current,
          due_at: 5.days.from_now,
          cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
        )

        ReceivableAllocation.create!(
          tenant: tenant,
          receivable: receivable,
          sequence: 1,
          allocated_party: beneficiary,
          gross_amount: receivable.gross_amount,
          tax_reserve_amount: "0.00",
          status: "OPEN"
        )

        receivable
      end

      def create_shared_cnpj_physician_bundle_for_tenant!(tenant, suffix:)
        hospital = Party.create!(
          tenant: tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-hospital")
        )
        legal_entity = Party.create!(
          tenant: tenant,
          kind: "LEGAL_ENTITY_PJ",
          legal_name: "Clinica #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-legal-entity")
        )
        physician_one = Party.create!(
          tenant: tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Medico Um #{suffix}",
          document_number: valid_cpf_from_seed("#{suffix}-physician-1")
        )
        physician_two = Party.create!(
          tenant: tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Medico Dois #{suffix}",
          document_number: valid_cpf_from_seed("#{suffix}-physician-2")
        )

        PhysicianLegalEntityMembership.create!(
          tenant: tenant,
          physician_party: physician_one,
          legal_entity_party: legal_entity,
          membership_role: "ADMIN",
          status: "ACTIVE"
        )
        PhysicianLegalEntityMembership.create!(
          tenant: tenant,
          physician_party: physician_two,
          legal_entity_party: legal_entity,
          membership_role: "MEMBER",
          status: "ACTIVE"
        )

        kind = ReceivableKind.create!(
          tenant: tenant,
          code: "physician_shift_#{suffix}",
          name: "Physician Shift #{suffix}",
          source_family: "PHYSICIAN"
        )

        receivable = Receivable.create!(
          tenant: tenant,
          receivable_kind: kind,
          debtor_party: hospital,
          creditor_party: legal_entity,
          beneficiary_party: legal_entity,
          external_reference: "external-#{suffix}",
          gross_amount: "100.00",
          currency: "BRL",
          performed_at: Time.current,
          due_at: 3.days.from_now,
          cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
        )

        allocation = ReceivableAllocation.create!(
          tenant: tenant,
          receivable: receivable,
          sequence: 1,
          allocated_party: legal_entity,
          physician_party: physician_one,
          gross_amount: "100.00",
          tax_reserve_amount: "0.00",
          status: "OPEN"
        )

        {
          hospital: hospital,
          legal_entity: legal_entity,
          physician_one: physician_one,
          physician_two: physician_two,
          receivable: receivable,
          allocation: allocation
        }
      end

      def with_stubbed_settlement_service(service_object)
        original = Api::V1::ReceivablesController.instance_method(:receivable_settlement_service)
        Api::V1::ReceivablesController.send(:define_method, :receivable_settlement_service) { service_object }
        yield
      ensure
        Api::V1::ReceivablesController.send(:define_method, :receivable_settlement_service, original)
      end

      def create_direct_anticipation_request!(
        tenant:,
        receivable:,
        allocation:,
        requester_party:,
        idempotency_key:,
        requested_amount:,
        discount_rate:,
        discount_amount:,
        net_amount:,
        status:
      )
        AnticipationRequest.create!(
          tenant: tenant,
          receivable: receivable,
          receivable_allocation: allocation,
          requester_party: requester_party,
          idempotency_key: idempotency_key,
          requested_amount: requested_amount,
          discount_rate: discount_rate,
          discount_amount: discount_amount,
          net_amount: net_amount,
          status: status,
          channel: "API",
          requested_at: Time.current,
          settlement_target_date: BusinessCalendar.next_business_day(from: Time.current),
          metadata: {}
        )
      end

      def create_document_signature_challenges!(receivable:, actor_party:, suffix:)
        {
          email: create_document_signature_challenge!(
            receivable: receivable,
            actor_party: actor_party,
            channel: "EMAIL",
            destination_masked: "m***#{suffix}@example.com"
          ),
          whatsapp: create_document_signature_challenge!(
            receivable: receivable,
            actor_party: actor_party,
            channel: "WHATSAPP",
            destination_masked: "+55*******#{suffix.to_s[-3..]}"
          )
        }
      end

      def create_document_signature_challenge!(receivable:, actor_party:, channel:, destination_masked:)
        AuthChallenge.create!(
          tenant: @tenant,
          actor_party: actor_party,
          purpose: "DOCUMENT_SIGNATURE_CONFIRMATION",
          delivery_channel: channel,
          destination_masked: destination_masked,
          code_digest: Digest::SHA256.hexdigest("verified"),
          status: "VERIFIED",
          attempts: 1,
          max_attempts: 5,
          expires_at: 30.minutes.from_now,
          request_id: SecureRandom.uuid,
          target_type: "Receivable",
          target_id: receivable.id,
          metadata: {}
        )
      end

      def insert_legacy_outbox_without_payload_hash!(tenant_id:, aggregate_type:, aggregate_id:, event_type:, idempotency_key:, payload:)
        connection = ActiveRecord::Base.connection
        timestamp = Time.utc(2026, 2, 21, 23, 59, 59)
        payload_json = payload.to_json

        connection.execute(<<~SQL)
          INSERT INTO outbox_events (
            id, tenant_id, aggregate_type, aggregate_id, event_type, status, attempts, idempotency_key, payload, created_at, updated_at
          ) VALUES (
            #{connection.quote(SecureRandom.uuid)},
            #{connection.quote(tenant_id)},
            #{connection.quote(aggregate_type)},
            #{connection.quote(aggregate_id)},
            #{connection.quote(event_type)},
            'PENDING',
            0,
            #{connection.quote(idempotency_key)},
            #{connection.quote(payload_json)}::jsonb,
            #{connection.quote(timestamp)},
            #{connection.quote(timestamp)}
          )
        SQL
      end
    end
  end
end
