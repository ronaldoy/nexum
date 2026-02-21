require "test_helper"

module Integrations
  module Fdic
    class DispatchOperationTest < ActiveSupport::TestCase
      setup do
        @tenant = tenants(:default)
        @user = users(:one)
      end

      test "dispatches funding request and persists sent operation" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_funding_bundle!("fdic-dispatch-op-funding")
          outbox_event = create_fdic_funding_outbox_event!(
            anticipation_request: bundle[:anticipation_request],
            amount: "45.00",
            idempotency_key: "fdic-dispatch-op-funding-key"
          )

          provider = FakeProviderSuccess.new
          operation = nil

          with_stubbed_provider(provider) do
            operation = Integrations::Fdic::DispatchOperation.new.call(outbox_event: outbox_event)
          end

          assert_equal "FUNDING_REQUEST", operation.operation_type
          assert_equal "SENT", operation.status
          assert_equal "provider-funding-123", operation.provider_reference
          assert_equal BigDecimal("45.00"), operation.amount.to_d
          assert_equal bundle[:anticipation_request].id, operation.anticipation_request_id
          assert_equal 1, provider.funding_calls.size
          assert_equal 0, provider.settlement_calls.size

          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "FDIC_OPERATION_DISPATCHED",
            target_type: "FdicOperation",
            target_id: operation.id
          ).count
        end
      end

      test "dispatches settlement report and persists sent operation" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_funding_bundle!("fdic-dispatch-op-settlement")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "fdic-dispatch-op-settlement",
            fdic_amount: "30.00",
            beneficiary_amount: "70.00"
          )
          outbox_event = create_fdic_settlement_outbox_event!(
            settlement: settlement,
            amount: "30.00",
            idempotency_key: "fdic-dispatch-op-settlement-key"
          )

          provider = FakeProviderSuccess.new
          operation = nil

          with_stubbed_provider(provider) do
            operation = Integrations::Fdic::DispatchOperation.new.call(outbox_event: outbox_event)
          end

          assert_equal "SETTLEMENT_REPORT", operation.operation_type
          assert_equal "SENT", operation.status
          assert_equal settlement.id, operation.receivable_payment_settlement_id
          assert_equal "provider-settlement-123", operation.provider_reference
          assert_equal 0, provider.funding_calls.size
          assert_equal 1, provider.settlement_calls.size

          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "FDIC_OPERATION_DISPATCHED",
            target_type: "FdicOperation",
            target_id: operation.id
          ).count
        end
      end

      test "replays existing sent operation without redispatching provider" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_funding_bundle!("fdic-dispatch-op-replay")
          outbox_event = create_fdic_funding_outbox_event!(
            anticipation_request: bundle[:anticipation_request],
            amount: "45.00",
            idempotency_key: "fdic-dispatch-op-replay-key"
          )

          first_operation = nil
          with_stubbed_provider(FakeProviderSuccess.new) do
            first_operation = Integrations::Fdic::DispatchOperation.new.call(outbox_event: outbox_event)
          end

          replayed_operation = nil
          with_stubbed_provider(FakeProviderShouldNotBeCalled.new) do
            replayed_operation = Integrations::Fdic::DispatchOperation.new.call(outbox_event: outbox_event)
          end

          assert_equal first_operation.id, replayed_operation.id
          assert_equal "SENT", replayed_operation.status
          assert_equal 1, FdicOperation.where(tenant_id: @tenant.id, idempotency_key: "fdic-dispatch-op-replay-key").count
          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "FDIC_OPERATION_DISPATCHED",
            target_type: "FdicOperation",
            target_id: first_operation.id
          ).count
        end
      end

      test "persists failed operation and logs when provider fails" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_funding_bundle!("fdic-dispatch-op-failure")
          outbox_event = create_fdic_funding_outbox_event!(
            anticipation_request: bundle[:anticipation_request],
            amount: "45.00",
            idempotency_key: "fdic-dispatch-op-failure-key"
          )

          error = nil
          with_stubbed_provider(FakeProviderFailure.new) do
            error = assert_raises(Integrations::Fdic::RemoteError) do
              Integrations::Fdic::DispatchOperation.new.call(outbox_event: outbox_event)
            end
          end

          assert_equal "fdic_provider_timeout", error.code

          operation = FdicOperation.find_by!(tenant_id: @tenant.id, idempotency_key: "fdic-dispatch-op-failure-key")
          assert_equal "FAILED", operation.status
          assert_equal "fdic_provider_timeout", operation.last_error_code
          assert_equal "FDIC provider timeout.", operation.last_error_message

          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "FDIC_OPERATION_DISPATCH_FAILED",
            target_type: "FdicOperation",
            target_id: operation.id
          ).count
        end
      end

      private

      def create_funding_bundle!(suffix)
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
          due_at: 10.days.from_now,
          cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date),
          status: "ANTICIPATION_REQUESTED"
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
        anticipation_request = AnticipationRequest.create!(
          tenant: @tenant,
          receivable: receivable,
          receivable_allocation: allocation,
          requester_party: supplier,
          idempotency_key: "idem-anticipation-#{suffix}",
          requested_amount: "50.00",
          discount_rate: "0.10000000",
          discount_amount: "5.00",
          net_amount: "45.00",
          status: "APPROVED",
          channel: "API",
          requested_at: Time.current
        )

        {
          receivable: receivable,
          allocation: allocation,
          anticipation_request: anticipation_request,
          supplier: supplier
        }
      end

      def create_settlement!(bundle:, suffix:, fdic_amount:, beneficiary_amount:)
        ReceivablePaymentSettlement.create!(
          tenant: @tenant,
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          paid_amount: "100.00",
          cnpj_amount: "0.00",
          fdic_amount: fdic_amount,
          beneficiary_amount: beneficiary_amount,
          fdic_balance_before: fdic_amount,
          fdic_balance_after: "0.00",
          paid_at: Time.current,
          payment_reference: "payment-ref-#{suffix}",
          idempotency_key: "settlement-#{suffix}",
          request_id: SecureRandom.uuid,
          metadata: {}
        )
      end

      def create_fdic_funding_outbox_event!(anticipation_request:, amount:, idempotency_key:)
        OutboxEvent.create!(
          tenant: @tenant,
          aggregate_type: "AnticipationRequest",
          aggregate_id: anticipation_request.id,
          event_type: "ANTICIPATION_FIDC_FUNDING_REQUESTED",
          status: "PENDING",
          idempotency_key: idempotency_key,
          payload: {
            "anticipation_request_id" => anticipation_request.id,
            "receivable_id" => anticipation_request.receivable_id,
            "amount" => amount,
            "currency" => "BRL",
            "provider" => "MOCK",
            "operation_kind" => "FUNDING_REQUEST",
            "operation_idempotency_key" => idempotency_key,
            "provider_request_control_key" => idempotency_key
          }
        )
      end

      def create_fdic_settlement_outbox_event!(settlement:, amount:, idempotency_key:)
        OutboxEvent.create!(
          tenant: @tenant,
          aggregate_type: "ReceivablePaymentSettlement",
          aggregate_id: settlement.id,
          event_type: "RECEIVABLE_FIDC_SETTLEMENT_REPORTED",
          status: "PENDING",
          idempotency_key: idempotency_key,
          payload: {
            "settlement_id" => settlement.id,
            "receivable_id" => settlement.receivable_id,
            "amount" => amount,
            "currency" => "BRL",
            "provider" => "MOCK",
            "operation_kind" => "SETTLEMENT_REPORT",
            "operation_idempotency_key" => idempotency_key,
            "provider_request_control_key" => idempotency_key
          }
        )
      end

      def with_stubbed_provider(provider)
        singleton = Integrations::Fdic::ProviderRegistry.singleton_class
        original_fetch = Integrations::Fdic::ProviderRegistry.method(:fetch)
        singleton.send(:define_method, :fetch) { |provider_code:| provider }
        yield
      ensure
        singleton.send(:define_method, :fetch, original_fetch)
      end

      class FakeProviderSuccess
        attr_reader :funding_calls, :settlement_calls

        def initialize
          @funding_calls = []
          @settlement_calls = []
        end

        def request_funding!(tenant_id:, anticipation_request:, payload:, idempotency_key:)
          @funding_calls << {
            tenant_id: tenant_id,
            anticipation_request_id: anticipation_request.id,
            idempotency_key: idempotency_key
          }
          Integrations::Fdic::OperationResult.new(
            provider_reference: "provider-funding-123",
            status: "SENT",
            metadata: { "status" => "SENT" }
          )
        end

        def report_settlement!(tenant_id:, settlement:, payload:, idempotency_key:)
          @settlement_calls << {
            tenant_id: tenant_id,
            settlement_id: settlement.id,
            idempotency_key: idempotency_key
          }
          Integrations::Fdic::OperationResult.new(
            provider_reference: "provider-settlement-123",
            status: "SENT",
            metadata: { "status" => "SENT" }
          )
        end
      end

      class FakeProviderShouldNotBeCalled < FakeProviderSuccess
        def request_funding!(tenant_id:, anticipation_request:, payload:, idempotency_key:)
          raise "request_funding! should not be called for sent operation replay"
        end

        def report_settlement!(tenant_id:, settlement:, payload:, idempotency_key:)
          raise "report_settlement! should not be called for sent operation replay"
        end
      end

      class FakeProviderFailure < FakeProviderSuccess
        def request_funding!(tenant_id:, anticipation_request:, payload:, idempotency_key:)
          raise Integrations::Fdic::RemoteError.new(
            code: "fdic_provider_timeout",
            message: "FDIC provider timeout.",
            http_status: 504
          )
        end
      end
    end
  end
end
