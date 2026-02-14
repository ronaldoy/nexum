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

      test "lists receivables scoped by tenant context" do
        get api_v1_receivables_path, headers: authorization_headers(@read_token), as: :json

        assert_response :success
        assert_equal 1, response.parsed_body.dig("meta", "count")
        assert_equal @receivable.id, response.parsed_body.dig("data", 0, "id")
        assert_equal "123.45", response.parsed_body.dig("data", 0, "gross_amount")
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
        end
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
          content_type: "application/pdf"
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
          consumed_at: Time.current,
          request_id: SecureRandom.uuid,
          target_type: "Receivable",
          target_id: receivable.id,
          metadata: {}
        )
      end
    end
  end
end
