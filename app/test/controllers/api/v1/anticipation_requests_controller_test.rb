require "test_helper"
require "digest"

module Api
  module V1
    class AnticipationRequestsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @tenant = tenants(:default)
        @secondary_tenant = tenants(:secondary)
        @user = users(:one)

        @write_token = nil
        @read_token = nil
        @confirm_token = nil
        @challenge_token = nil
        @tenant_bundle = nil
        @secondary_bundle = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          @user.update!(role: "ops_admin")
        end

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          _, @write_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Anticipation Write API",
            scopes: %w[anticipation_requests:write]
          )
          _, @read_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Read-Only API",
            scopes: %w[receivables:read receivables:history]
          )
          _, @confirm_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Anticipation Confirm API",
            scopes: %w[anticipation_requests:confirm]
          )
          _, @challenge_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Anticipation Challenge API",
            scopes: %w[anticipation_requests:challenge]
          )
          @tenant_bundle = create_receivable_bundle!(tenant: @tenant, suffix: "tenant-a")
        end

        with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @user.id, role: @user.role) do
          @secondary_bundle = create_receivable_bundle!(tenant: @secondary_tenant, suffix: "tenant-b")
        end
      end

      test "creates anticipation request with append-only event and log" do
        idempotency_key = "idem-create-001"

        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@write_token, idempotency_key: idempotency_key),
          params: create_payload,
          as: :json

        assert_response :created
        body = response.parsed_body

        assert_equal false, body.dig("data", "replayed")
        assert_equal "REQUESTED", body.dig("data", "status")
        assert_equal "100.00", body.dig("data", "requested_amount")
        assert_equal "5.00", body.dig("data", "discount_amount")
        assert_equal "95.00", body.dig("data", "net_amount")
        assert_equal idempotency_key, body.dig("data", "idempotency_key")
        provenance = body.dig("data", "receivable_provenance")
        assert_equal @tenant_bundle[:debtor].legal_name, provenance.dig("hospital", "legal_name")
        assert_equal @tenant_bundle[:creditor].legal_name, provenance.dig("owning_organization", "legal_name")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          created = AnticipationRequest.find(body.dig("data", "id"))
          assert_equal "ANTICIPATION_REQUESTED", created.receivable.reload.status
          assert_equal 1, ReceivableEvent.where(receivable_id: created.receivable_id, event_type: "ANTICIPATION_REQUESTED").count
          assert_equal 1, ActionIpLog.where(target_id: created.id, action_type: "ANTICIPATION_REQUEST_CREATED").count
        end
      end

      test "exposes hospital ownership provenance for fdic funding visibility" do
        custom_bundle = nil
        owning_org = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          custom_bundle = create_receivable_bundle!(tenant: @tenant, suffix: "owned-provenance")
          owning_org = Party.create!(
            tenant: @tenant,
            kind: "LEGAL_ENTITY_PJ",
            legal_name: "Grupo Hospitalar Provenance",
            document_number: valid_cnpj_from_seed("owned-provenance-org")
          )
          HospitalOwnership.create!(
            tenant: @tenant,
            organization_party: owning_org,
            hospital_party: custom_bundle[:debtor]
          )
        end

        payload = create_payload(
          receivable_id: custom_bundle[:receivable].id,
          receivable_allocation_id: custom_bundle[:allocation].id,
          requester_party_id: custom_bundle[:beneficiary].id
        )

        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-owned-provenance-001"),
          params: payload,
          as: :json

        assert_response :created
        provenance = response.parsed_body.dig("data", "receivable_provenance")
        assert_equal custom_bundle[:debtor].legal_name, provenance.dig("hospital", "legal_name")
        assert_equal owning_org.legal_name, provenance.dig("owning_organization", "legal_name")
      end

      test "replays same idempotency key with same payload safely" do
        idempotency_key = "idem-replay-001"

        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@write_token, idempotency_key: idempotency_key),
          params: create_payload,
          as: :json
        assert_response :created
        first_id = response.parsed_body.dig("data", "id")

        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@write_token, idempotency_key: idempotency_key),
          params: create_payload,
          as: :json

        assert_response :ok
        body = response.parsed_body
        assert_equal true, body.dig("data", "replayed")
        assert_equal first_id, body.dig("data", "id")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, AnticipationRequest.where(tenant_id: @tenant.id, idempotency_key: idempotency_key).count
          assert_equal 1, ReceivableEvent.where(receivable_id: @tenant_bundle[:receivable].id, event_type: "ANTICIPATION_REQUESTED").count
          assert_equal 1, ActionIpLog.where(action_type: "ANTICIPATION_REQUEST_CREATED", target_id: first_id).count
          assert_equal 1, ActionIpLog.where(action_type: "ANTICIPATION_REQUEST_REPLAYED", target_id: first_id).count
        end
      end

      test "returns conflict when idempotency key is reused with different payload" do
        idempotency_key = "idem-conflict-001"

        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@write_token, idempotency_key: idempotency_key),
          params: create_payload,
          as: :json
        assert_response :created

        changed_payload = create_payload.deep_dup
        changed_payload[:anticipation_request][:requested_amount] = "110.00"

        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@write_token, idempotency_key: idempotency_key),
          params: changed_payload,
          as: :json

        assert_response :conflict
        assert_equal "idempotency_key_reused_with_different_payload", response.parsed_body.dig("error", "code")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, AnticipationRequest.where(tenant_id: @tenant.id, idempotency_key: idempotency_key).count
          assert_equal 1, ReceivableEvent.where(receivable_id: @tenant_bundle[:receivable].id, event_type: "ANTICIPATION_REQUESTED").count
        end
      end

      test "requires anticipation write scope" do
        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@read_token, idempotency_key: "idem-no-scope-001"),
          params: create_payload,
          as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "enforces tenant isolation for receivables" do
        payload = create_payload(
          receivable_id: @secondary_bundle[:receivable].id,
          receivable_allocation_id: @secondary_bundle[:allocation].id,
          requester_party_id: @secondary_bundle[:beneficiary].id
        )

        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-tenant-001"),
          params: payload,
          as: :json

        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")
      end

      test "enforces shared cnpj split limit for physician anticipation" do
        shared_bundle = nil
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          shared_bundle = create_shared_cnpj_physician_bundle!(tenant: @tenant, suffix: "shared-cnpj-limit")
        end

        payload = create_payload(
          receivable_id: shared_bundle[:receivable].id,
          receivable_allocation_id: shared_bundle[:allocation].id,
          requester_party_id: shared_bundle[:physician_one].id
        )
        payload[:anticipation_request][:requested_amount] = "71.00"

        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@write_token, idempotency_key: "idem-shared-cnpj-limit-001"),
          params: payload,
          as: :json

        assert_response :unprocessable_entity
        assert_equal "requested_amount_exceeds_available", response.parsed_body.dig("error", "code")
      end

      test "requires idempotency key header for create" do
        post api_v1_anticipation_requests_path,
          headers: authorization_headers(@write_token),
          params: create_payload,
          as: :json

        assert_response :unprocessable_entity
        assert_equal "missing_idempotency_key", response.parsed_body.dig("error", "code")
      end

      test "issues email and whatsapp challenges and queues outbox dispatch events" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-issue-001"
          )
        end

        post issue_challenges_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@challenge_token, idempotency_key: "idem-issue-001"),
          params: challenge_issue_payload,
          as: :json

        assert_response :created
        body = response.parsed_body
        assert_equal false, body.dig("data", "replayed")
        assert_equal anticipation_request.id, body.dig("data", "anticipation_request_id")
        assert_equal 2, body.dig("data", "challenges").size
        assert_includes body.dig("data", "challenges").map { |entry| entry["delivery_channel"] }, "EMAIL"
        assert_includes body.dig("data", "challenges").map { |entry| entry["delivery_channel"] }, "WHATSAPP"

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          challenges = AuthChallenge.where(tenant_id: @tenant.id, target_type: "AnticipationRequest", target_id: anticipation_request.id)
          assert_equal 2, challenges.count
          assert_equal %w[EMAIL WHATSAPP], challenges.order(delivery_channel: :asc).pluck(:delivery_channel)
          assert_equal %w[PENDING PENDING], challenges.order(delivery_channel: :asc).pluck(:status)

          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, idempotency_key: "idem-issue-001", event_type: "ANTICIPATION_CONFIRMATION_CHALLENGES_ISSUED").count
          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, idempotency_key: "idem-issue-001:email", event_type: "AUTH_CHALLENGE_EMAIL_DISPATCH_REQUESTED").count
          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, idempotency_key: "idem-issue-001:whatsapp", event_type: "AUTH_CHALLENGE_WHATSAPP_DISPATCH_REQUESTED").count

          assert_equal 1, ReceivableEvent.where(receivable_id: anticipation_request.receivable_id, event_type: "ANTICIPATION_CONFIRMATION_CHALLENGES_ISSUED").count
          assert_equal 1, ActionIpLog.where(action_type: "ANTICIPATION_CHALLENGES_ISSUED", target_id: anticipation_request.id).count
        end
      end

      test "replays challenge issuance for same idempotency key and payload" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-issue-002"
          )
        end

        2.times do
          post issue_challenges_api_v1_anticipation_request_path(anticipation_request.id),
            headers: authorization_headers(@challenge_token, idempotency_key: "idem-issue-replay-001"),
            params: challenge_issue_payload,
            as: :json
        end

        assert_response :ok
        assert_equal true, response.parsed_body.dig("data", "replayed")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 2, AuthChallenge.where(tenant_id: @tenant.id, target_type: "AnticipationRequest", target_id: anticipation_request.id).count
          assert_equal 1, OutboxEvent.where(tenant_id: @tenant.id, idempotency_key: "idem-issue-replay-001").count
          assert_equal 1, ActionIpLog.where(action_type: "ANTICIPATION_CHALLENGES_REPLAYED", target_id: anticipation_request.id).count
        end
      end

      test "returns conflict when challenge issuance idempotency key is reused with different payload" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-issue-003"
          )
        end

        post issue_challenges_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@challenge_token, idempotency_key: "idem-issue-conflict-001"),
          params: challenge_issue_payload,
          as: :json
        assert_response :created

        changed_payload = challenge_issue_payload.deep_dup
        changed_payload[:challenge_issue][:whatsapp_destination] = "+55 (11) 90000-9999"

        post issue_challenges_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@challenge_token, idempotency_key: "idem-issue-conflict-001"),
          params: changed_payload,
          as: :json

        assert_response :conflict
        assert_equal "idempotency_key_reused_with_different_payload", response.parsed_body.dig("error", "code")
      end

      test "rejects challenge issuance with invalid destination and logs failure" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-issue-invalid-001"
          )
        end

        post issue_challenges_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@challenge_token, idempotency_key: "idem-issue-invalid-001"),
          params: {
            challenge_issue: {
              email_destination: "invalid-email",
              whatsapp_destination: "+55 (11) 91234-5678"
            }
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "invalid_email_destination", response.parsed_body.dig("error", "code")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "ANTICIPATION_CHALLENGES_ISSUE_FAILED",
            target_id: anticipation_request.id
          ).count
        end
      end

      test "requires challenge scope for issue challenges endpoint" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-issue-004"
          )
        end

        post issue_challenges_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@write_token, idempotency_key: "idem-issue-scope-001"),
          params: challenge_issue_payload,
          as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "requires idempotency key header for issue challenges endpoint" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-issue-005"
          )
        end

        post issue_challenges_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@challenge_token),
          params: challenge_issue_payload,
          as: :json

        assert_response :unprocessable_entity
        assert_equal "missing_idempotency_key", response.parsed_body.dig("error", "code")
      end

      test "enforces tenant isolation for issue challenges endpoint" do
        secondary_anticipation = nil

        with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @user.id, role: @user.role) do
          secondary_anticipation = create_direct_anticipation_request!(
            tenant_bundle: @secondary_bundle,
            idempotency_key: "idem-internal-issue-secondary-001",
            tenant: @secondary_tenant
          )
        end

        post issue_challenges_api_v1_anticipation_request_path(secondary_anticipation.id),
          headers: authorization_headers(@challenge_token, idempotency_key: "idem-issue-tenant-001"),
          params: challenge_issue_payload,
          as: :json

        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")
      end

      test "confirms anticipation request with email and whatsapp codes" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-confirm-001"
          )
          create_confirmation_challenges!(
            anticipation_request: anticipation_request,
            email_code: "123456",
            whatsapp_code: "654321"
          )
        end

        post confirm_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@confirm_token, idempotency_key: "idem-confirm-001"),
          params: {
            confirmation: {
              email_code: "123456",
              whatsapp_code: "654321"
            }
          },
          as: :json

        assert_response :success
        assert_equal false, response.parsed_body.dig("data", "replayed")
        assert_equal "APPROVED", response.parsed_body.dig("data", "status")
        assert_equal %w[EMAIL WHATSAPP], response.parsed_body.dig("data", "confirmation_channels")
        assert response.parsed_body.dig("data", "confirmed_at").present?

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request.reload
          assert_equal "APPROVED", anticipation_request.status
          assert_equal 1, ReceivableEvent.where(receivable_id: anticipation_request.receivable_id, event_type: "ANTICIPATION_CONFIRMED").count

          email_challenge = AuthChallenge.find_by!(
            tenant_id: @tenant.id,
            target_type: "AnticipationRequest",
            target_id: anticipation_request.id,
            delivery_channel: "EMAIL"
          )
          whatsapp_challenge = AuthChallenge.find_by!(
            tenant_id: @tenant.id,
            target_type: "AnticipationRequest",
            target_id: anticipation_request.id,
            delivery_channel: "WHATSAPP"
          )
          assert_equal "VERIFIED", email_challenge.status
          assert_equal "VERIFIED", whatsapp_challenge.status

          assert_equal 1, ActionIpLog.where(action_type: "ANTICIPATION_CONFIRMED", target_id: anticipation_request.id).count

          assert_equal 0, OutboxEvent.where(
            tenant_id: @tenant.id,
            aggregate_id: anticipation_request.id,
            event_type: "RECEIVABLE_ESCROW_EXCESS_PAYOUT_REQUESTED"
          ).count
        end
      end

      test "replays confirmation when already approved with same codes" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-confirm-002"
          )
          create_confirmation_challenges!(
            anticipation_request: anticipation_request,
            email_code: "222222",
            whatsapp_code: "333333"
          )
        end

        2.times do
          post confirm_api_v1_anticipation_request_path(anticipation_request.id),
            headers: authorization_headers(@confirm_token, idempotency_key: "idem-confirm-replay-001"),
            params: {
              confirmation: {
                email_code: "222222",
                whatsapp_code: "333333"
              }
            },
            as: :json
        end

        assert_response :success
        assert_equal true, response.parsed_body.dig("data", "replayed")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, ReceivableEvent.where(receivable_id: anticipation_request.receivable_id, event_type: "ANTICIPATION_CONFIRMED").count
          assert_equal 1, ActionIpLog.where(action_type: "ANTICIPATION_CONFIRM_REPLAYED", target_id: anticipation_request.id).count
        end
      end

      test "returns conflict when confirmation idempotency key is reused with different codes" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-confirm-006"
          )
          create_confirmation_challenges!(
            anticipation_request: anticipation_request,
            email_code: "121212",
            whatsapp_code: "343434"
          )
        end

        post confirm_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@confirm_token, idempotency_key: "idem-confirm-conflict-001"),
          params: {
            confirmation: {
              email_code: "121212",
              whatsapp_code: "343434"
            }
          },
          as: :json
        assert_response :success

        post confirm_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@confirm_token, idempotency_key: "idem-confirm-conflict-001"),
          params: {
            confirmation: {
              email_code: "121212",
              whatsapp_code: "999999"
            }
          },
          as: :json

        assert_response :conflict
        assert_equal "idempotency_key_reused_with_different_payload", response.parsed_body.dig("error", "code")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          assert_equal 1, ReceivableEvent.where(receivable_id: anticipation_request.receivable_id, event_type: "ANTICIPATION_CONFIRMED").count
        end
      end

      test "rejects confirmation when code is invalid and logs failure" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-confirm-003"
          )
          create_confirmation_challenges!(
            anticipation_request: anticipation_request,
            email_code: "444444",
            whatsapp_code: "555555"
          )
        end

        post confirm_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@confirm_token, idempotency_key: "idem-confirm-invalid-001"),
          params: {
            confirmation: {
              email_code: "444444",
              whatsapp_code: "000000"
            }
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "invalid_whatsapp_code", response.parsed_body.dig("error", "code")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request.reload
          assert_equal "REQUESTED", anticipation_request.status
          assert_equal 0, ReceivableEvent.where(receivable_id: anticipation_request.receivable_id, event_type: "ANTICIPATION_CONFIRMED").count
          assert_equal 1, ActionIpLog.where(action_type: "ANTICIPATION_CONFIRM_FAILED", target_id: anticipation_request.id).count

          whatsapp_challenge = AuthChallenge.find_by!(
            tenant_id: @tenant.id,
            target_type: "AnticipationRequest",
            target_id: anticipation_request.id,
            delivery_channel: "WHATSAPP"
          )
          assert_equal 1, whatsapp_challenge.attempts
          assert_equal "PENDING", whatsapp_challenge.status
        end
      end

      test "requires confirm scope for confirmation endpoint" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-confirm-004"
          )
          create_confirmation_challenges!(
            anticipation_request: anticipation_request,
            email_code: "777777",
            whatsapp_code: "888888"
          )
        end

        post confirm_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@write_token, idempotency_key: "idem-confirm-scope-001"),
          params: {
            confirmation: {
              email_code: "777777",
              whatsapp_code: "888888"
            }
          },
          as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "requires idempotency key header for confirmation endpoint" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-confirm-005"
          )
          create_confirmation_challenges!(
            anticipation_request: anticipation_request,
            email_code: "909090",
            whatsapp_code: "010101"
          )
        end

        post confirm_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@confirm_token),
          params: {
            confirmation: {
              email_code: "909090",
              whatsapp_code: "010101"
            }
          },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "missing_idempotency_key", response.parsed_body.dig("error", "code")
      end

      test "issues challenges then confirms using outbox-generated codes" do
        anticipation_request = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          anticipation_request = create_direct_anticipation_request!(
            tenant_bundle: @tenant_bundle,
            idempotency_key: "idem-internal-e2e-001"
          )
        end

        post issue_challenges_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@challenge_token, idempotency_key: "idem-e2e-issue-001"),
          params: challenge_issue_payload,
          as: :json
        assert_response :created

        email_code = nil
        whatsapp_code = nil
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          email_code = OutboxEvent.find_by!(
            tenant_id: @tenant.id,
            aggregate_id: anticipation_request.id,
            event_type: "AUTH_CHALLENGE_EMAIL_DISPATCH_REQUESTED"
          ).payload.fetch("code")
          whatsapp_code = OutboxEvent.find_by!(
            tenant_id: @tenant.id,
            aggregate_id: anticipation_request.id,
            event_type: "AUTH_CHALLENGE_WHATSAPP_DISPATCH_REQUESTED"
          ).payload.fetch("code")
        end

        post confirm_api_v1_anticipation_request_path(anticipation_request.id),
          headers: authorization_headers(@confirm_token, idempotency_key: "idem-e2e-confirm-001"),
          params: {
            confirmation: {
              email_code: email_code,
              whatsapp_code: whatsapp_code
            }
          },
          as: :json

        assert_response :success
        assert_equal "APPROVED", response.parsed_body.dig("data", "status")
      end

      private

      def create_payload(receivable_id: @tenant_bundle[:receivable].id, receivable_allocation_id: @tenant_bundle[:allocation].id, requester_party_id: @tenant_bundle[:beneficiary].id)
        {
          anticipation_request: {
            receivable_id: receivable_id,
            receivable_allocation_id: receivable_allocation_id,
            requester_party_id: requester_party_id,
            requested_amount: "100.00",
            discount_rate: "0.05000000",
            channel: "API",
            metadata: { "source" => "supplier_portal" }
          }
        }
      end

      def authorization_headers(raw_token, idempotency_key: nil)
        headers = { "Authorization" => "Bearer #{raw_token}" }
        headers["Idempotency-Key"] = idempotency_key if idempotency_key
        headers
      end

      def challenge_issue_payload
        {
          challenge_issue: {
            email_destination: "medico@example.com",
            whatsapp_destination: "+55 (11) 91234-5678"
          }
        }
      end

      def create_receivable_bundle!(tenant:, suffix:)
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
          gross_amount: "200.00",
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
          gross_amount: "200.00",
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

      def create_direct_anticipation_request!(tenant_bundle:, idempotency_key:, tenant: @tenant)
        AnticipationRequest.create!(
          tenant: tenant,
          receivable: tenant_bundle[:receivable],
          receivable_allocation: tenant_bundle[:allocation],
          requester_party: tenant_bundle[:beneficiary],
          idempotency_key: idempotency_key,
          requested_amount: "100.00",
          discount_rate: "0.05000000",
          discount_amount: "5.00",
          net_amount: "95.00",
          status: "REQUESTED",
          channel: "API",
          requested_at: Time.current,
          settlement_target_date: BusinessCalendar.next_business_day(from: Time.current),
          metadata: {}
        )
      end

      def create_shared_cnpj_physician_bundle!(tenant:, suffix:)
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
          code: "physician_shift_shared_#{suffix}",
          name: "Physician Shift Shared #{suffix}",
          source_family: "PHYSICIAN"
        )

        receivable = Receivable.create!(
          tenant: tenant,
          receivable_kind: kind,
          debtor_party: hospital,
          creditor_party: legal_entity,
          beneficiary_party: legal_entity,
          external_reference: "external-shared-#{suffix}",
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

      def create_confirmation_challenges!(anticipation_request:, email_code:, whatsapp_code:)
        create_auth_challenge!(
          anticipation_request: anticipation_request,
          channel: "EMAIL",
          destination_masked: "m***@example.com",
          code: email_code
        )
        create_auth_challenge!(
          anticipation_request: anticipation_request,
          channel: "WHATSAPP",
          destination_masked: "+55*******321",
          code: whatsapp_code
        )
      end

      def create_auth_challenge!(anticipation_request:, channel:, destination_masked:, code:)
        AuthChallenge.create!(
          tenant: @tenant,
          actor_party: anticipation_request.requester_party,
          purpose: "ANTICIPATION_CONFIRMATION",
          delivery_channel: channel,
          destination_masked: destination_masked,
          code_digest: Digest::SHA256.hexdigest(code),
          status: "PENDING",
          attempts: 0,
          max_attempts: 5,
          expires_at: 30.minutes.from_now,
          request_id: SecureRandom.uuid,
          target_type: "AnticipationRequest",
          target_id: anticipation_request.id,
          metadata: {}
        )
      end
    end
  end
end
