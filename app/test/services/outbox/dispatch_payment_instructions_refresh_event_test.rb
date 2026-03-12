require "test_helper"

module Outbox
  class DispatchPaymentInstructionsRefreshEventTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @user = users(:one)
    end

    test "dispatches payment instructions refresh event and persists PIX instructions" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
        bundle = create_receivable_bundle!("refresh-payment-instructions-success")
        outbox_event = create_refresh_outbox_event!(
          receivable: bundle[:receivable],
          allocation: bundle[:allocation],
          provider: "STARKBANK",
          idempotency_key: "idem-refresh-payment-instructions-success"
        )
        provider = FakeEscrowPaymentInstructionsProvider.new

        with_environment("ESCROW_ENABLE_STARKBANK" => "true") do
          with_stubbed_escrow_provider(provider) do
            result = Outbox::DispatchEvent.new.call(outbox_event_id: outbox_event.id)

            assert_equal "SENT", result.status
          end
        end

        account = EscrowAccount.find_by!(
          tenant_id: @tenant.id,
          party_id: bundle[:supplier].id,
          provider: "STARKBANK"
        )
        assert_equal "workspace-refresh-123", account.provider_account_id
        assert_equal "f47ac10b-58cc-4372-a567-0e02b2c3d479", account.metadata.dig("payment_instructions", "pix_key")
        assert_equal 1, provider.open_account_calls.size
        assert_equal 1, provider.fetch_payment_instructions_calls.size
        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "ESCROW_PAYMENT_INSTRUCTIONS_REFRESHED",
          target_type: "Receivable",
          target_id: bundle[:receivable].id
        ).count
      end
    end

    private

    def create_receivable_bundle!(suffix)
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

    def create_refresh_outbox_event!(receivable:, allocation:, provider:, idempotency_key:)
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
          provider_account_id: "workspace-refresh-123",
          provider_request_id: "workspace-user-refresh-123",
          status: "ACTIVE",
          metadata: {
            "workspace" => {
              "id" => "workspace-refresh-123",
              "username" => "workspace-user-refresh-123"
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
          "beneficiary_name" => "Fornecedor refresh payment instructions",
          "beneficiary_document_number" => "12345678000195",
          "last_synced_at" => Time.current.utc.iso8601(6)
        }
      end
    end
  end
end
