require "test_helper"
require "integrations/hospital_api/error"

module Outbox
  class DispatchHospitalPaymentInstructionsEventTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @user = users(:one)
    end

    test "dispatches hospital payment instructions sync event" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        bundle = create_hospital_receivable_bundle!("hospital-payment-instructions-success")
        outbox_event = create_hospital_payment_instructions_outbox_event!(
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          hospital_party: bundle[:hospital],
          provider: "STARKBANK",
          idempotency_key: "idem-hospital-payment-instructions-success"
        )
        provider = FakeEscrowPaymentInstructionsProvider.new
        client = FakeHospitalApiClient.new

        with_environment(
          "HOSPITAL_API_BASE_URL" => "https://hospital.example.com",
          "HOSPITAL_API_BEARER_TOKEN" => "hospital-api-token",
          "ESCROW_ENABLE_STARKBANK" => "true"
        ) do
          with_stubbed_escrow_provider(provider) do
            with_stubbed_hospital_client(client) do
              result = Outbox::DispatchEvent.new.call(outbox_event_id: outbox_event.id)

              assert_equal "SENT", result.status
            end
          end
        end

        assert_equal 1, client.requests.size
        request = client.requests.first
        assert_equal "/api/v1/receivable_payment_instructions", request.fetch(:path)
        assert_equal "idem-hospital-payment-instructions-success", request.fetch(:idempotency_key)
        assert_equal bundle[:receivable].id, request.dig(:body, "receivable", "id")
        assert_equal bundle[:allocation].id, request.dig(:body, "receivable_allocation", "id")
        assert_equal "PIX", request.dig(:body, "payment_instructions", "payment_rail")
        assert_equal "f47ac10b-58cc-4372-a567-0e02b2c3d479", request.dig(:body, "payment_instructions", "pix_key")
        assert_equal bundle[:hospital].document_type, request.dig(:body, "hospital", "document_type")
        assert_equal "**.***.***/****-#{bundle[:hospital].document_number[-2, 2]}", request.dig(:body, "hospital", "document_number_masked")
        assert_nil request.dig(:body, "hospital", "document_number")
        assert_equal bundle[:supplier].document_type, request.dig(:body, "operational_party", "document_type")
        assert_equal "**.***.***/****-#{bundle[:supplier].document_number[-2, 2]}", request.dig(:body, "operational_party", "document_number_masked")
        assert_nil request.dig(:body, "operational_party", "document_number")

        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "HOSPITAL_PAYMENT_INSTRUCTIONS_SYNCED",
          target_type: "Receivable",
          target_id: bundle[:receivable].id
        ).count
      end
    end

    test "retries and dead-letters hospital payment instructions sync on client failure" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        bundle = create_hospital_receivable_bundle!("hospital-payment-instructions-failure")
        outbox_event = create_hospital_payment_instructions_outbox_event!(
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          hospital_party: bundle[:hospital],
          provider: "STARKBANK",
          idempotency_key: "idem-hospital-payment-instructions-failure"
        )
        provider = FakeEscrowPaymentInstructionsProvider.new
        dispatcher = Outbox::DispatchEvent.new(max_attempts: 2, backoff_strategy: ->(_attempt) { 0 })

        with_environment(
          "HOSPITAL_API_BASE_URL" => "https://hospital.example.com",
          "HOSPITAL_API_BEARER_TOKEN" => "hospital-api-token",
          "ESCROW_ENABLE_STARKBANK" => "true"
        ) do
          with_stubbed_escrow_provider(provider) do
            with_stubbed_hospital_client(FakeFailingHospitalApiClient.new) do
              first = dispatcher.call(outbox_event_id: outbox_event.id)
              second = dispatcher.call(outbox_event_id: outbox_event.id)

              assert_equal "RETRY_SCHEDULED", first.status
              assert_equal "DEAD_LETTER", second.status
            end
          end
        end

        dead_letter_attempt = OutboxDispatchAttempt.where(
          tenant_id: @tenant.id,
          outbox_event_id: outbox_event.id,
          status: "DEAD_LETTER"
        ).first
        assert dead_letter_attempt.present?
        assert_equal "hospital_api_unreachable", dead_letter_attempt.error_code

        assert_equal 2, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_FAILED",
          target_type: "Receivable",
          target_id: bundle[:receivable].id
        ).count
      end
    end

    test "logs hospital payment instructions failure when escrow resolution fails" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        bundle = create_hospital_receivable_bundle!("hospital-payment-instructions-escrow-failure")
        outbox_event = create_hospital_payment_instructions_outbox_event!(
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          hospital_party: bundle[:hospital],
          provider: "STARKBANK",
          idempotency_key: "idem-hospital-payment-instructions-escrow-failure"
        )
        dispatcher = Outbox::DispatchEvent.new(max_attempts: 1, backoff_strategy: ->(_attempt) { 0 })

        with_environment(
          "HOSPITAL_API_BASE_URL" => "https://hospital.example.com",
          "HOSPITAL_API_BEARER_TOKEN" => "hospital-api-token",
          "ESCROW_ENABLE_STARKBANK" => "true"
        ) do
          with_stubbed_escrow_provider(FakeEscrowFailingProvider.new) do
            with_stubbed_hospital_client(FakeHospitalApiClient.new) do
              result = dispatcher.call(outbox_event_id: outbox_event.id)

              assert_equal "DEAD_LETTER", result.status
            end
          end
        end

        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_FAILED",
          target_type: "Receivable",
          target_id: bundle[:receivable].id
        ).count
      end
    end

    test "hospital sync reuses the provisioned account and cached PIX instructions after refresh" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        bundle = create_hospital_receivable_bundle!("hospital-payment-instructions-refresh-sequence")
        refresh_event = create_payment_instructions_refresh_outbox_event!(
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          provider: "STARKBANK",
          idempotency_key: "idem-payment-instructions-refresh-sequence"
        )
        hospital_event = create_hospital_payment_instructions_outbox_event!(
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          hospital_party: bundle[:hospital],
          provider: "STARKBANK",
          idempotency_key: "idem-hospital-payment-instructions-refresh-sequence"
        )
        provider = FakeEscrowPaymentInstructionsProvider.new
        client = FakeHospitalApiClient.new

        with_environment(
          "HOSPITAL_API_BASE_URL" => "https://hospital.example.com",
          "HOSPITAL_API_BEARER_TOKEN" => "hospital-api-token",
          "ESCROW_ENABLE_STARKBANK" => "true"
        ) do
          with_stubbed_escrow_provider(provider) do
            with_stubbed_hospital_client(client) do
              refresh_result = Outbox::DispatchEvent.new.call(outbox_event_id: refresh_event.id)
              hospital_result = Outbox::DispatchEvent.new.call(outbox_event_id: hospital_event.id)

              assert_equal "SENT", refresh_result.status
              assert_equal "SENT", hospital_result.status
            end
          end
        end

        assert_equal 1, EscrowAccount.where(
          tenant_id: @tenant.id,
          party_id: bundle[:supplier].id,
          provider: "STARKBANK"
        ).count
        assert_equal 1, provider.open_account_calls.size
        assert_equal 1, provider.fetch_payment_instructions_calls.size
        assert_equal 1, client.requests.size
      end
    end

    private

    def create_hospital_receivable_bundle!(suffix)
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
        hospital: hospital,
        supplier: supplier,
        receivable: receivable,
        allocation: allocation
      }
    end

    def create_hospital_payment_instructions_outbox_event!(receivable:, allocation:, hospital_party:, provider:, idempotency_key:)
      OutboxEvent.create!(
        tenant: @tenant,
        aggregate_type: "Receivable",
        aggregate_id: receivable.id,
        event_type: "RECEIVABLE_HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_REQUESTED",
        status: "PENDING",
        idempotency_key: idempotency_key,
        payload: {
          "receivable_id" => receivable.id,
          "receivable_allocation_id" => allocation.id,
          "hospital_party_id" => hospital_party.id,
          "operational_party_id" => allocation.allocated_party_id,
          "provider" => provider,
          "payment_instruction_idempotency_key" => "#{allocation.allocated_party_id}:escrow_account",
          "hospital_sync_idempotency_key" => idempotency_key
        }
      )
    end

    def create_payment_instructions_refresh_outbox_event!(receivable:, allocation:, provider:, idempotency_key:)
      OutboxEvent.create!(
        tenant: @tenant,
        aggregate_type: "Receivable",
        aggregate_id: receivable.id,
        event_type: "RECEIVABLE_ESCROW_PAYMENT_INSTRUCTIONS_REFRESH_REQUESTED",
        status: "PENDING",
        idempotency_key: idempotency_key,
        payload: {
          "receivable_id" => receivable.id,
          "receivable_allocation_id" => allocation.id,
          "operational_party_id" => allocation.allocated_party_id,
          "provider" => provider,
          "payment_instruction_idempotency_key" => "#{allocation.allocated_party_id}:escrow_account"
        }
      )
    end

    def with_stubbed_escrow_provider(provider)
      registry_singleton = Integrations::Escrow::ProviderRegistry.singleton_class
      original_fetch = Integrations::Escrow::ProviderRegistry.method(:fetch)
      registry_singleton.send(:define_method, :fetch) { |provider_code:, tenant_id: nil, tenant_slug: nil| provider }
      yield
    ensure
      registry_singleton.send(:define_method, :fetch, original_fetch)
    end

    def with_stubbed_hospital_client(client)
      singleton = Integrations::HospitalApi::Client.singleton_class
      original_new = Integrations::HospitalApi::Client.method(:new)
      singleton.send(:define_method, :new) { |**_kwargs| client }
      yield
    ensure
      singleton.send(:define_method, :new, original_new)
    end

    def with_environment(overrides)
      previous = {}
      overrides.each do |key, value|
        previous[key] = ENV[key]
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
      yield
    ensure
      previous.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    class FakeEscrowPaymentInstructionsProvider
      attr_reader :open_account_calls, :fetch_payment_instructions_calls

      def initialize
        @open_account_calls = []
        @fetch_payment_instructions_calls = []
      end

      def provider_code
        "STARKBANK"
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
          provider_account_id: "workspace-hospital-api-123",
          provider_request_id: "workspace-user-hospital-api-123",
          status: "ACTIVE",
          metadata: {
            "workspace" => {
              "id" => "workspace-hospital-api-123",
              "username" => "workspace-user-hospital-api-123"
            }
          }
        )
      end

      def fetch_payment_instructions!(tenant_id:, escrow_account:)
        @fetch_payment_instructions_calls << {
          tenant_id: tenant_id,
          escrow_account_id: escrow_account.id
        }
        {
          "payment_rail" => "PIX",
          "pix_key" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
          "pix_key_type" => "EVP",
          "pix_key_status" => "REGISTERED",
          "bank_name" => "Stark Bank",
          "bank_code" => "20018183",
          "account_type" => "payment",
          "beneficiary_name" => "Fornecedor hospital payment instructions",
          "beneficiary_document_number" => "12345678000195",
          "last_synced_at" => Time.current.utc.iso8601(6)
        }
      end
    end

    class FakeHospitalApiClient
      attr_reader :requests

      def initialize
        @requests = []
      end

      def upsert_payment_instructions!(path:, body:, idempotency_key:)
        @requests << {
          path: path,
          body: body,
          idempotency_key: idempotency_key
        }
        {
          "http_status" => 200,
          "response_body" => { "status" => "ok" }
        }
      end
    end

    class FakeFailingHospitalApiClient < FakeHospitalApiClient
      def upsert_payment_instructions!(path:, body:, idempotency_key:)
        raise Integrations::HospitalApi::RemoteError.new(
          code: "hospital_api_unreachable",
          message: "Hospital API endpoint is unreachable.",
          http_status: 503
        )
      end
    end

    class FakeEscrowFailingProvider < FakeEscrowPaymentInstructionsProvider
      def fetch_payment_instructions!(tenant_id:, escrow_account:)
        raise Integrations::Escrow::ValidationError.new(
          code: "payment_instructions_invalid",
          message: "Escrow provider returned invalid PIX payment instructions."
        )
      end
    end
  end
end
