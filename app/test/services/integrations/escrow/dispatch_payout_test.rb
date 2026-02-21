require "test_helper"

module Integrations
  module Escrow
    class DispatchPayoutTest < ActiveSupport::TestCase
      setup do
        @tenant = tenants(:default)
        @user = users(:one)
      end

      test "dispatches payout and persists escrow account and sent payout" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-success")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-success",
            cnpj_amount: "0.00",
            fdic_amount: "5.00",
            beneficiary_amount: "95.00"
          )
          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-success"
          )

          fake_provider = FakeProviderSuccess.new
          payout = nil

          with_stubbed_provider(fake_provider) do
            payout = Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
          end

          assert_equal "SENT", payout.status
          assert_equal "provider-transfer-123", payout.provider_transfer_id
          assert_equal BigDecimal("95.00"), payout.amount.to_d
          assert_equal 1, fake_provider.open_account_calls.size
          assert_equal 1, fake_provider.create_payout_calls.size

          account = EscrowAccount.find_by!(tenant_id: @tenant.id, party_id: bundle[:supplier].id, provider: "QITECH")
          assert_equal "ACTIVE", account.status
          assert_equal "provider-account-123", account.provider_account_id
          assert_equal payout.escrow_account_id, account.id

          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "ESCROW_PAYOUT_DISPATCHED",
            target_type: "EscrowPayout",
            target_id: payout.id
          ).count
        end
      end

      test "returns existing sent payout without dispatching provider again" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-replay")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-replay",
            cnpj_amount: "0.00",
            fdic_amount: "5.00",
            beneficiary_amount: "95.00"
          )

          account = EscrowAccount.create!(
            tenant: @tenant,
            party: bundle[:supplier],
            provider: "QITECH",
            account_type: "ESCROW",
            status: "ACTIVE",
            provider_account_id: "provider-account-replay",
            provider_request_id: "provider-request-replay",
            last_synced_at: Time.current,
            metadata: {}
          )

          existing_payout = EscrowPayout.create!(
            tenant: @tenant,
            receivable_payment_settlement: settlement,
            party: bundle[:supplier],
            escrow_account: account,
            provider: "QITECH",
            status: "SENT",
            amount: "95.00",
            currency: "BRL",
            idempotency_key: "idem-dispatch-payout-replay",
            provider_transfer_id: "provider-transfer-replay",
            requested_at: Time.current,
            processed_at: Time.current,
            metadata: {}
          )

          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-replay"
          )

          returned = nil
          with_stubbed_provider(FakeProviderShouldNotBeCalled.new) do
            returned = Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
          end

          assert_equal existing_payout.id, returned.id
          assert_equal "SENT", returned.status
          assert_equal 1, EscrowPayout.where(tenant_id: @tenant.id, idempotency_key: "idem-dispatch-payout-replay").count
          assert_equal 0, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "ESCROW_PAYOUT_DISPATCHED",
            target_type: "EscrowPayout",
            target_id: existing_payout.id
          ).count
        end
      end

      test "persists payout failure and logs when provider create payout fails" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-failure")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-failure",
            cnpj_amount: "0.00",
            fdic_amount: "5.00",
            beneficiary_amount: "95.00"
          )
          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-failure"
          )

          error = nil
          with_stubbed_provider(FakeProviderFailure.new) do
            error = assert_raises(Integrations::Escrow::RemoteError) do
              Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
            end
          end

          assert_equal "qitech_timeout", error.code

          payout = EscrowPayout.find_by!(tenant_id: @tenant.id, idempotency_key: "idem-dispatch-payout-failure")
          assert_equal "FAILED", payout.status
          assert_equal "qitech_timeout", payout.last_error_code
          assert_equal "Provider timeout.", payout.last_error_message

          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "ESCROW_PAYOUT_DISPATCH_FAILED",
            target_type: "EscrowPayout",
            target_id: payout.id
          ).count
        end
      end

      test "rejects excess payout amount that differs from settlement beneficiary amount" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-mismatch")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-mismatch",
            cnpj_amount: "0.00",
            fdic_amount: "5.00",
            beneficiary_amount: "95.00"
          )
          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-mismatch",
            amount: "94.99"
          )

          error = assert_raises(Integrations::Escrow::ValidationError) do
            Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
          end

          assert_equal "escrow_excess_amount_mismatch", error.code
          assert_nil EscrowPayout.find_by(tenant_id: @tenant.id, idempotency_key: "idem-dispatch-payout-mismatch")
        end
      end

      private

      def create_escrow_outbox_event!(settlement:, recipient_party:, idempotency_key:, amount: nil)
        payload_amount = amount || settlement.beneficiary_amount.to_d.to_s("F")

        OutboxEvent.create!(
          tenant: @tenant,
          aggregate_type: "ReceivablePaymentSettlement",
          aggregate_id: settlement.id,
          event_type: "RECEIVABLE_ESCROW_EXCESS_PAYOUT_REQUESTED",
          status: "PENDING",
          idempotency_key: idempotency_key,
          payload: {
            "settlement_id" => settlement.id,
            "receivable_id" => settlement.receivable_id,
            "recipient_party_id" => recipient_party.id,
            "amount" => payload_amount,
            "currency" => "BRL",
            "provider" => "QITECH",
            "payout_kind" => "EXCESS",
            "payout_idempotency_key" => idempotency_key,
            "account_idempotency_key" => "#{recipient_party.id}:escrow_account",
            "provider_request_control_key" => idempotency_key
          }
        )
      end

      def create_supplier_bundle!(suffix)
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

        {
          receivable: receivable,
          allocation: allocation,
          supplier: supplier
        }
      end

      def create_settlement!(bundle:, suffix:, cnpj_amount:, fdic_amount:, beneficiary_amount:)
        ReceivablePaymentSettlement.create!(
          tenant: @tenant,
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          paid_amount: "100.00",
          cnpj_amount: cnpj_amount,
          fdic_amount: fdic_amount,
          beneficiary_amount: beneficiary_amount,
          fdic_balance_before: fdic_amount,
          fdic_balance_after: "0.00",
          paid_at: Time.current,
          payment_reference: "hospital-payment-#{suffix}",
          idempotency_key: "idem-settlement-#{suffix}",
          request_id: SecureRandom.uuid,
          metadata: {}
        )
      end

      def with_stubbed_provider(provider)
        singleton = Integrations::Escrow::ProviderRegistry.singleton_class
        original_fetch = Integrations::Escrow::ProviderRegistry.method(:fetch)
        singleton.send(:define_method, :fetch) { |provider_code:| provider }
        yield
      ensure
        singleton.send(:define_method, :fetch, original_fetch)
      end

      class FakeProviderSuccess
        attr_reader :open_account_calls, :create_payout_calls

        def initialize
          @open_account_calls = []
          @create_payout_calls = []
        end

        def provider_code
          "QITECH"
        end

        def account_from_party_metadata(party:)
          nil
        end

        def open_escrow_account!(tenant_id:, party:, idempotency_key:, metadata:)
          @open_account_calls << {
            tenant_id: tenant_id,
            party_id: party.id,
            idempotency_key: idempotency_key
          }
          Integrations::Escrow::AccountProvisionResult.new(
            provider_account_id: "provider-account-123",
            provider_request_id: "provider-request-123",
            status: "ACTIVE",
            metadata: {
              "account_info" => {
                "branch_number" => "0001",
                "account_number" => "12345678",
                "account_digit" => "9",
                "account_type" => "payment_account"
              }
            }
          )
        end

        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          @create_payout_calls << {
            tenant_id: tenant_id,
            escrow_account_id: escrow_account.id,
            recipient_party_id: recipient_party.id,
            amount: amount,
            currency: currency,
            idempotency_key: idempotency_key
          }
          Integrations::Escrow::PayoutResult.new(
            provider_transfer_id: "provider-transfer-123",
            status: "SENT",
            metadata: { "status" => "SENT" }
          )
        end
      end

      class FakeProviderShouldNotBeCalled < FakeProviderSuccess
        def open_escrow_account!(tenant_id:, party:, idempotency_key:, metadata:)
          raise "open_escrow_account! should not be called for sent payout replay"
        end

        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          raise "create_payout! should not be called for sent payout replay"
        end
      end

      class FakeProviderFailure < FakeProviderSuccess
        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          raise Integrations::Escrow::RemoteError.new(
            code: "qitech_timeout",
            message: "Provider timeout.",
            http_status: 504
          )
        end
      end
    end
  end
end
