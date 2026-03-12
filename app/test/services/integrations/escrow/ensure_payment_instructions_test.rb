require "test_helper"

module Integrations
  module Escrow
    class EnsurePaymentInstructionsTest < ActiveSupport::TestCase
      setup do
        @tenant = tenants(:default)
        @user = users(:one)
      end

      test "provisions operational account and persists fetched PIX instructions" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_receivable_bundle!("ensure-payment-instructions")
          provider = FakeProvider.new

          result = nil
          with_environment("ESCROW_ENABLE_STARKBANK" => "true") do
            with_stubbed_provider(provider) do
              result = EnsurePaymentInstructions.new.call(
                tenant_id: @tenant.id,
                receivable: bundle[:receivable],
                receivable_allocation: bundle[:allocation],
                provider_code: "STARKBANK"
              )
            end
          end

          assert_equal "STARKBANK", result.provider_code
          assert_equal bundle[:supplier].id, result.operational_party.id
          assert_equal "PIX", result.payment_instructions.fetch("payment_rail")
          assert_equal "f47ac10b-58cc-4372-a567-0e02b2c3d479", result.payment_instructions.fetch("pix_key")

          account = EscrowAccount.find_by!(
            tenant_id: @tenant.id,
            party_id: bundle[:supplier].id,
            provider: "STARKBANK"
          )
          assert_equal "workspace-ensure-123", account.provider_account_id
          assert_equal "f47ac10b-58cc-4372-a567-0e02b2c3d479", account.metadata.dig("payment_instructions", "pix_key")
          assert_equal 1, provider.open_account_calls.size
          assert_equal 1, provider.fetch_payment_instructions_calls.size
        end
      end

      test "reuses cached payment instructions without fetching provider again" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_receivable_bundle!("ensure-payment-instructions-cached")

          EscrowAccount.create!(
            tenant: @tenant,
            party: bundle[:supplier],
            provider: "STARKBANK",
            account_type: "ESCROW",
            status: "ACTIVE",
            provider_account_id: "workspace-ensure-cached-123",
            provider_request_id: "workspace-user-cached-123",
            metadata: {
              "payment_instructions" => {
                "payment_rail" => "PIX",
                "pix_key" => "cached-key",
                "pix_key_type" => "EVP",
                "pix_key_status" => "REGISTERED",
                "beneficiary_name" => bundle[:supplier].legal_name,
                "last_synced_at" => Time.current.utc.iso8601(6)
              }
            }
          )

          provider = FakeProvider.new
          result = nil

          with_environment("ESCROW_ENABLE_STARKBANK" => "true") do
            with_stubbed_provider(provider) do
              result = EnsurePaymentInstructions.new.call(
                tenant_id: @tenant.id,
                receivable: bundle[:receivable],
                receivable_allocation: bundle[:allocation]
              )
            end
          end

          assert_equal "cached-key", result.payment_instructions.fetch("pix_key")
          assert_equal 0, provider.open_account_calls.size
          assert_equal 0, provider.fetch_payment_instructions_calls.size
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

      def with_stubbed_provider(provider)
        registry_singleton = Integrations::Escrow::ProviderRegistry.singleton_class
        provider_singleton = Integrations::Escrow::ProviderConfig.singleton_class
        original_fetch = Integrations::Escrow::ProviderRegistry.method(:fetch)
        original_default_provider = Integrations::Escrow::ProviderConfig.method(:default_provider)
        registry_singleton.send(:define_method, :fetch) { |provider_code:, tenant_id: nil, tenant_slug: nil| provider }
        provider_singleton.send(:define_method, :default_provider) { |tenant_id:| "STARKBANK" }
        yield
      ensure
        registry_singleton.send(:define_method, :fetch, original_fetch)
        provider_singleton.send(:define_method, :default_provider, original_default_provider)
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

      class FakeProvider
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
            provider_account_id: "workspace-ensure-123",
            provider_request_id: "workspace-user-ensure-123",
            status: "ACTIVE",
            metadata: {
              "workspace" => {
                "id" => "workspace-ensure-123",
                "username" => "workspace-user-ensure-123"
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
            "beneficiary_name" => "Fornecedor ensure payment instructions",
            "last_synced_at" => Time.current.utc.iso8601(6)
          }
        end
      end
    end
  end
end
