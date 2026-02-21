require "test_helper"
require "json"
require "openssl"

module Webhooks
  class EscrowControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @user = users(:one)
    end

    test "rejects webhook request with invalid signature" do
      with_environment(qitech_secret_env(@tenant.slug) => "secret-key") do
        payload = {
          "event_id" => "evt-invalid-signature",
          "request_control_key" => "missing-payout",
          "status" => "SENT"
        }

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: @tenant.slug),
          params: JSON.generate(payload),
          headers: json_webhook_headers(signature: "bad-signature")

        assert_response :unauthorized
        assert_equal "webhook_signature_invalid", response.parsed_body.dig("error", "code")
      end
    end

    test "returns generic authentication failure for unknown tenant slug" do
      with_environment(qitech_secret_env("non-existent-tenant") => "secret-key") do
        payload = {
          "event_id" => "evt-unknown-tenant",
          "request_control_key" => "missing-payout",
          "status" => "SENT"
        }
        body = JSON.generate(payload)

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: "non-existent-tenant"),
          params: body,
          headers: json_webhook_headers(signature: hmac_signature(body: body, secret: "secret-key"))

        assert_response :unauthorized
        assert_equal "webhook_signature_invalid", response.parsed_body.dig("error", "code")
      end
    end

    test "reconciles payout webhook and stores processed receipt" do
      payout = nil

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        payout = create_payout_bundle!(suffix: "webhook-success")[:payout]
      end

      with_environment(qitech_secret_env(@tenant.slug) => "secret-key") do
        payload = {
          "event_id" => "evt-webhook-success",
          "request_control_key" => payout.idempotency_key,
          "end_to_end_id" => "end-to-end-success",
          "status" => "SUCCESS"
        }
        body = JSON.generate(payload)

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: @tenant.slug),
          params: body,
          headers: json_webhook_headers(signature: hmac_signature(body: body, secret: "secret-key"))

        assert_response :accepted
        assert_equal "processed", response.parsed_body.dig("data", "status")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          payout.reload
          assert_equal "SENT", payout.status
          assert_equal "end-to-end-success", payout.provider_transfer_id

          receipt = ProviderWebhookReceipt.find_by!(
            tenant_id: @tenant.id,
            provider: "QITECH",
            provider_event_id: "evt-webhook-success"
          )
          assert_equal "PROCESSED", receipt.status
        end
      end
    end

    test "replays duplicate webhook event with same payload" do
      payout = nil

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        payout = create_payout_bundle!(suffix: "webhook-replay")[:payout]
      end

      with_environment(qitech_secret_env(@tenant.slug) => "secret-key") do
        payload = {
          "event_id" => "evt-webhook-replay",
          "request_control_key" => payout.idempotency_key,
          "status" => "SUCCESS"
        }
        body = JSON.generate(payload)
        headers = json_webhook_headers(signature: hmac_signature(body: body, secret: "secret-key"))

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: @tenant.slug),
          params: body,
          headers: headers
        assert_response :accepted

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: @tenant.slug),
          params: body,
          headers: headers
        assert_response :success
        assert_equal "replayed", response.parsed_body.dig("data", "status")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          assert_equal 1, ProviderWebhookReceipt.where(
            tenant_id: @tenant.id,
            provider: "QITECH",
            provider_event_id: "evt-webhook-replay"
          ).count
        end
      end
    end

    test "rejects spoofed header event id when payload event id is present" do
      payout = nil

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        payout = create_payout_bundle!(suffix: "webhook-header-spoof")[:payout]
      end

      with_environment(qitech_secret_env(@tenant.slug) => "secret-key") do
        payload = {
          "event_id" => "evt-webhook-header-spoof",
          "request_control_key" => payout.idempotency_key,
          "status" => "SUCCESS"
        }
        body = JSON.generate(payload)

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: @tenant.slug),
          params: body,
          headers: json_webhook_headers(signature: hmac_signature(body: body, secret: "secret-key"))
        assert_response :accepted

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: @tenant.slug),
          params: body,
          headers: json_webhook_headers(
            signature: hmac_signature(body: body, secret: "secret-key")
          ).merge("X-Webhook-Id" => "header-event-b")

        assert_response :bad_request
        assert_equal "webhook_event_id_mismatch", response.parsed_body.dig("error", "code")
      end
    end

    test "rejects duplicate webhook id when payload differs" do
      payout = nil

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        payout = create_payout_bundle!(suffix: "webhook-conflict")[:payout]
      end

      with_environment(qitech_secret_env(@tenant.slug) => "secret-key") do
        first_payload = {
          "event_id" => "evt-webhook-conflict",
          "request_control_key" => payout.idempotency_key,
          "status" => "SUCCESS"
        }
        first_body = JSON.generate(first_payload)

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: @tenant.slug),
          params: first_body,
          headers: json_webhook_headers(signature: hmac_signature(body: first_body, secret: "secret-key"))
        assert_response :accepted

        second_payload = first_payload.merge("status" => "FAILED")
        second_body = JSON.generate(second_payload)

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: @tenant.slug),
          params: second_body,
          headers: json_webhook_headers(signature: hmac_signature(body: second_body, secret: "secret-key"))

        assert_response :conflict
        assert_equal "webhook_event_reused_with_different_payload", response.parsed_body.dig("error", "code")
      end
    end

    test "records reconciliation exception when webhook cannot find matching resource" do
      with_environment(qitech_secret_env(@tenant.slug) => "secret-key") do
        payload = {
          "event_id" => "evt-webhook-ignored",
          "request_control_key" => "non-existent-payout",
          "status" => "SUCCESS"
        }
        body = JSON.generate(payload)

        post webhooks_escrow_path(provider: "QITECH", tenant_slug: @tenant.slug),
          params: body,
          headers: json_webhook_headers(signature: hmac_signature(body: body, secret: "secret-key"))

        assert_response :accepted
        assert_equal "ignored", response.parsed_body.dig("data", "status")

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          receipt = ProviderWebhookReceipt.find_by!(
            tenant_id: @tenant.id,
            provider: "QITECH",
            provider_event_id: "evt-webhook-ignored"
          )
          assert_equal "IGNORED", receipt.status

          reconciliation_exception = ReconciliationException.find_by!(
            tenant_id: @tenant.id,
            source: "ESCROW_WEBHOOK",
            provider: "QITECH",
            external_event_id: "evt-webhook-ignored",
            code: "escrow_webhook_resource_not_found"
          )
          assert_equal "OPEN", reconciliation_exception.status
          assert_equal 1, reconciliation_exception.occurrences_count
        end
      end
    end

    private

    def qitech_secret_env(tenant_slug)
      normalized_slug = tenant_slug.to_s.upcase.gsub(/[^A-Z0-9]+/, "_")
      "QITECH_WEBHOOK_SECRET__#{normalized_slug}"
    end

    def json_webhook_headers(signature:)
      {
        "CONTENT_TYPE" => "application/json",
        "X-QITECH-Signature" => signature
      }
    end

    def hmac_signature(body:, secret:)
      OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    end

    def with_environment(overrides)
      previous = {}
      overrides.each_key { |key| previous[key] = ENV[key] }

      overrides.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end

      yield
    ensure
      previous.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end

    def create_payout_bundle!(suffix:)
      hospital = Party.create!(
        tenant: @tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-hospital")
      )
      supplier = Party.create!(
        tenant: @tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-supplier")
      )
      kind = ReceivableKind.create!(
        tenant: @tenant,
        code: "supplier_invoice_#{suffix}",
        name: "Supplier Invoice #{suffix}",
        source_family: "SUPPLIER"
      )
      receivable = Receivable.create!(
        tenant: @tenant,
        receivable_kind: kind,
        debtor_party: hospital,
        creditor_party: supplier,
        beneficiary_party: supplier,
        external_reference: "external-#{suffix}",
        gross_amount: "100.00",
        currency: "BRL",
        performed_at: Time.current,
        due_at: 5.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: supplier,
        gross_amount: "100.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )
      settlement = ReceivablePaymentSettlement.create!(
        tenant: @tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        paid_amount: "100.00",
        cnpj_amount: "0.00",
        fdic_amount: "5.00",
        beneficiary_amount: "95.00",
        fdic_balance_before: "5.00",
        fdic_balance_after: "0.00",
        paid_at: Time.current,
        payment_reference: "payment-ref-#{suffix}",
        idempotency_key: "settlement-#{suffix}",
        request_id: SecureRandom.uuid,
        metadata: {}
      )
      escrow_account = EscrowAccount.create!(
        tenant: @tenant,
        party: supplier,
        provider: "QITECH",
        account_type: "ESCROW",
        status: "ACTIVE",
        provider_account_id: "account-#{suffix}",
        provider_request_id: "account-request-#{suffix}",
        metadata: {
          "account_info" => {
            "branch_number" => "0001",
            "account_number" => "12345678",
            "account_digit" => "9",
            "account_type" => "payment_account",
            "taxpayer_id" => supplier.document_number
          }
        }
      )
      payout = EscrowPayout.create!(
        tenant: @tenant,
        receivable_payment_settlement: settlement,
        party: supplier,
        escrow_account: escrow_account,
        provider: "QITECH",
        status: "PENDING",
        amount: "95.00",
        currency: "BRL",
        idempotency_key: "payout-#{suffix}",
        requested_at: Time.current,
        metadata: {
          "payload" => {
            "provider_request_control_key" => "payout-#{suffix}"
          }
        }
      )

      {
        payout: payout,
        settlement: settlement,
        supplier: supplier,
        escrow_account: escrow_account
      }
    end
  end
end
