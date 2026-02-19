require "test_helper"

module Integrations
  module Escrow
    class ReconcileWebhookEventTest < ActiveSupport::TestCase
      setup do
        @tenant = tenants(:default)
        @user = users(:one)
      end

      test "reconciles payout by request_control_key and sets sent state" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_payout_bundle!(suffix: "reconcile-payout")
          payout = bundle.fetch(:payout)

          result = ReconcileWebhookEvent.new(
            tenant_id: @tenant.id,
            provider: "QITECH",
            payload: {
              "event_id" => "evt-reconcile-payout",
              "request_control_key" => payout.idempotency_key,
              "end_to_end_id" => "provider-transfer-reconcile",
              "status" => "SUCCESS"
            },
            provider_event_id: "evt-reconcile-payout",
            request_id: SecureRandom.uuid,
            request_ip: "127.0.0.1",
            user_agent: "test-suite",
            endpoint_path: "/webhooks/escrow/qitech/#{@tenant.slug}",
            http_method: "POST"
          ).call

          payout.reload
          assert_equal "PROCESSED", result.status
          assert_equal payout.id, result.target_id
          assert_equal "SENT", payout.status
          assert_equal "provider-transfer-reconcile", payout.provider_transfer_id
          assert_equal "evt-reconcile-payout", payout.metadata.dig("webhook_reconciliation", "provider_event_id")
        end
      end

      test "reconciles escrow account by provider request id" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          supplier = Party.create!(
            tenant: @tenant,
            kind: "SUPPLIER",
            legal_name: "Fornecedor reconcile-account",
            document_number: valid_cnpj_from_seed("reconcile-account-supplier")
          )

          account = EscrowAccount.create!(
            tenant: @tenant,
            party: supplier,
            provider: "QITECH",
            account_type: "ESCROW",
            status: "PENDING",
            provider_request_id: "account-request-reconcile",
            metadata: {}
          )

          result = ReconcileWebhookEvent.new(
            tenant_id: @tenant.id,
            provider: "QITECH",
            payload: {
              "event_id" => "evt-reconcile-account",
              "account_request_key" => "account-request-reconcile",
              "account_key" => "provider-account-reconcile",
              "status" => "APPROVED"
            },
            provider_event_id: "evt-reconcile-account",
            request_id: SecureRandom.uuid,
            request_ip: "127.0.0.1",
            user_agent: "test-suite",
            endpoint_path: "/webhooks/escrow/qitech/#{@tenant.slug}",
            http_method: "POST"
          ).call

          account.reload
          assert_equal "PROCESSED", result.status
          assert_equal account.id, result.target_id
          assert_equal "ACTIVE", account.status
          assert_equal "provider-account-reconcile", account.provider_account_id
          assert_equal "evt-reconcile-account", account.metadata.dig("webhook_reconciliation", "provider_event_id")
        end
      end

      test "ignores unmatched webhook payload" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          result = ReconcileWebhookEvent.new(
            tenant_id: @tenant.id,
            provider: "QITECH",
            payload: {
              "event_id" => "evt-ignored",
              "status" => "SUCCESS"
            },
            provider_event_id: "evt-ignored",
            request_id: SecureRandom.uuid,
            request_ip: "127.0.0.1",
            user_agent: "test-suite",
            endpoint_path: "/webhooks/escrow/qitech/#{@tenant.slug}",
            http_method: "POST"
          ).call

          assert_equal "IGNORED", result.status
          assert_equal "resource_not_found", result.metadata["reason"]
        end
      end

      private

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
          metadata: {}
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
end
