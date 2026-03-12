require "test_helper"

module Integrations
  module Escrow
    module Providers
      class StarkBankTest < ActiveSupport::TestCase
        setup do
          @tenant = tenants(:default)
          @provider = StarkBank.new
        end

        test "fetches registered EVP inbound PIX key for operational account" do
          with_tenant_db_context(tenant_id: @tenant.id) do
            supplier = Party.create!(
              tenant: @tenant,
              kind: "SUPPLIER",
              legal_name: "Fornecedor Stark Inbound",
              document_number: valid_cnpj_from_seed("stark-inbound")
            )

            escrow_account = EscrowAccount.create!(
              tenant: @tenant,
              party: supplier,
              provider: "STARKBANK",
              account_type: "ESCROW",
              status: "ACTIVE",
              provider_account_id: "workspace-inbound-123",
              provider_request_id: "workspace-user-inbound-123",
              metadata: {}
            )

            preferred_key = FakeDictKey.new(
              id: "f47ac10b-58cc-4372-a567-0e02b2c3d479",
              type: "evp",
              status: "registered",
              bank_name: "Stark Bank",
              ispb: "20018183",
              account_type: "payment",
              name: "Fornecedor Stark Inbound",
              tax_id: supplier.document_number
            )
            secondary_key = FakeDictKey.new(
              id: "financeiro@example.com",
              type: "email",
              status: "registered",
              bank_name: "Stark Bank",
              ispb: "20018183",
              account_type: "payment",
              name: "Fornecedor Stark Inbound",
              tax_id: supplier.document_number
            )

            with_stubbed_workspace_user do
              with_stubbed_dict_keys([ secondary_key, preferred_key ]) do
                result = @provider.fetch_payment_instructions!(
                  tenant_id: @tenant.id,
                  escrow_account: escrow_account
                )

                assert_equal "PIX", result.fetch("payment_rail")
                assert_equal preferred_key.id, result.fetch("pix_key")
                assert_equal "EVP", result.fetch("pix_key_type")
                assert_equal "REGISTERED", result.fetch("pix_key_status")
                assert_equal "Stark Bank", result.fetch("bank_name")
                assert_equal "20018183", result.fetch("bank_code")
              end
            end
          end
        end

        private

        def with_stubbed_workspace_user
          singleton = StarkBankConfiguration.singleton_class
          original = StarkBankConfiguration.method(:workspace_user)
          singleton.send(:define_method, :workspace_user) do |workspace_id:, tenant_id: nil, tenant_slug: nil|
            Object.new
          end
          yield
        ensure
          singleton.send(:define_method, :workspace_user, original)
        end

        def with_stubbed_dict_keys(dict_keys)
          singleton = ::StarkBank::DictKey.singleton_class
          original = ::StarkBank::DictKey.method(:query)
          singleton.send(:define_method, :query) do |limit: nil, type: nil, after: nil, before: nil, ids: nil, status: nil, user: nil|
            dict_keys
          end
          yield
        ensure
          singleton.send(:define_method, :query, original)
        end

        FakeDictKey = Struct.new(
          :id,
          :type,
          :status,
          :bank_name,
          :ispb,
          :account_type,
          :name,
          :tax_id,
          keyword_init: true
        )
      end
    end
  end
end
