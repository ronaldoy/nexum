require "test_helper"

module Outbox
  class DispatchEscrowEventTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @user = users(:one)
    end

    test "dispatches escrow payout event and persists account and payout" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        bundle = create_supplier_bundle!("escrow-dispatch-success")
        settlement = create_settlement!(
          bundle: bundle,
          suffix: "escrow-dispatch-success",
          cnpj_amount: "0.00",
          fdic_amount: "5.00",
          beneficiary_amount: "95.00"
        )
        outbox_event = create_escrow_outbox_event!(
          settlement: settlement,
          recipient_party: bundle[:supplier],
          idempotency_key: "idem-escrow-dispatch-success"
        )

        fake_provider = FakeProviderSuccess.new
        with_stubbed_provider(fake_provider) do
          result = Outbox::DispatchEvent.new.call(outbox_event_id: outbox_event.id)

          assert_equal "SENT", result.status
          assert_equal 1, EscrowAccount.where(tenant_id: @tenant.id, party_id: bundle[:supplier].id, provider: "QITECH").count
          assert_equal 1, EscrowPayout.where(tenant_id: @tenant.id, receivable_payment_settlement_id: settlement.id, status: "SENT").count

          payout = EscrowPayout.find_by!(tenant_id: @tenant.id, receivable_payment_settlement_id: settlement.id)
          assert_equal BigDecimal("95.00"), payout.amount.to_d
          assert_equal "provider-transfer-123", payout.provider_transfer_id
        end
      end
    end

    test "retries and dead-letters escrow payout dispatch on provider failure" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        bundle = create_supplier_bundle!("escrow-dispatch-failure")
        settlement = create_settlement!(
          bundle: bundle,
          suffix: "escrow-dispatch-failure",
          cnpj_amount: "0.00",
          fdic_amount: "5.00",
          beneficiary_amount: "95.00"
        )
        outbox_event = create_escrow_outbox_event!(
          settlement: settlement,
          recipient_party: bundle[:supplier],
          idempotency_key: "idem-escrow-dispatch-failure"
        )

        dispatcher = Outbox::DispatchEvent.new(max_attempts: 2, backoff_strategy: ->(_attempt) { 0 })

        with_stubbed_provider(FakeProviderFailure.new) do
          first = dispatcher.call(outbox_event_id: outbox_event.id)
          second = dispatcher.call(outbox_event_id: outbox_event.id)

          assert_equal "RETRY_SCHEDULED", first.status
          assert_equal "DEAD_LETTER", second.status

          payout = EscrowPayout.find_by!(tenant_id: @tenant.id, idempotency_key: "idem-escrow-dispatch-failure")
          assert_equal "FAILED", payout.status
          assert_equal "qitech_timeout", payout.last_error_code

          dead_letter_attempt = OutboxDispatchAttempt.where(
            tenant_id: @tenant.id,
            outbox_event_id: outbox_event.id,
            status: "DEAD_LETTER"
          ).first
          assert dead_letter_attempt.present?
          assert_equal "qitech_timeout", dead_letter_attempt.error_code
        end
      end
    end

    private

    def create_escrow_outbox_event!(settlement:, recipient_party:, idempotency_key:)
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
          "amount" => settlement.beneficiary_amount.to_d.to_s("F"),
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
      def provider_code
        "QITECH"
      end

      def account_from_party_metadata(party:)
        nil
      end

      def open_escrow_account!(tenant_id:, party:, idempotency_key:, metadata:)
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
        Integrations::Escrow::PayoutResult.new(
          provider_transfer_id: "provider-transfer-123",
          status: "SENT",
          metadata: { "status" => "SENT" }
        )
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
