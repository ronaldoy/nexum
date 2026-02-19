require "test_helper"

module Integrations
  module Escrow
    module Providers
      class QiTechTest < ActiveSupport::TestCase
        setup do
          @tenant = tenants(:default)
        end

        test "sends EXCESS payout to destination account with matching taxpayer" do
          with_tenant_db_context(tenant_id: @tenant.id) do
            supplier = Party.create!(
              tenant: @tenant,
              kind: "SUPPLIER",
              legal_name: "Fornecedor QI Tech",
              document_number: valid_cnpj_from_seed("qitech-destination-match"),
              metadata: {
                "integrations" => {
                  "qitech" => {
                    "payout_destination_account" => {
                      "branch_number" => "1234",
                      "account_number" => "99999999",
                      "account_digit" => "1",
                      "account_type" => "payment_account",
                      "name" => "Fornecedor QI Tech",
                      "taxpayer_id" => valid_cnpj_from_seed("qitech-destination-match")
                    }
                  }
                }
              }
            )

            escrow_account = EscrowAccount.create!(
              tenant: @tenant,
              party: supplier,
              provider: "QITECH",
              account_type: "ESCROW",
              status: "ACTIVE",
              provider_account_id: "escrow-account-123",
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

            client = FakeClient.new
            provider = QiTech.new(client: client)

            with_environment("QITECH_SOURCE_ACCOUNT_KEY" => "source-account-key") do
              result = provider.create_payout!(
                tenant_id: @tenant.id,
                escrow_account: escrow_account,
                recipient_party: supplier,
                amount: BigDecimal("10.00"),
                currency: "BRL",
                idempotency_key: "idem-qitech-destination-match",
                metadata: { "payout_kind" => "EXCESS" }
              )

              assert_equal "SENT", result.status
              assert_equal "/v1/account/source-account-key/pix_transfer", client.last_path
              assert_equal "1234", client.last_body.dig("target_account", "branch_number")
              assert_equal supplier.document_number, client.last_body.dig("target_account", "taxpayer_id")
            end
          end
        end

        test "rejects payout when destination taxpayer id differs from party document" do
          with_tenant_db_context(tenant_id: @tenant.id) do
            supplier = Party.create!(
              tenant: @tenant,
              kind: "SUPPLIER",
              legal_name: "Fornecedor CPF CNPJ",
              document_number: valid_cnpj_from_seed("qitech-destination-mismatch"),
              metadata: {
                "integrations" => {
                  "qitech" => {
                    "payout_destination_account" => {
                      "branch_number" => "1234",
                      "account_number" => "99999999",
                      "account_digit" => "1",
                      "account_type" => "payment_account",
                      "name" => "Fornecedor CPF CNPJ",
                      "taxpayer_id" => valid_cnpj_from_seed("qitech-other-party")
                    }
                  }
                }
              }
            )

            escrow_account = EscrowAccount.create!(
              tenant: @tenant,
              party: supplier,
              provider: "QITECH",
              account_type: "ESCROW",
              status: "ACTIVE",
              provider_account_id: "escrow-account-456",
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

            provider = QiTech.new(client: FakeClient.new)

            with_environment("QITECH_SOURCE_ACCOUNT_KEY" => "source-account-key") do
              error = assert_raises(Integrations::Escrow::ValidationError) do
                provider.create_payout!(
                  tenant_id: @tenant.id,
                  escrow_account: escrow_account,
                  recipient_party: supplier,
                  amount: BigDecimal("10.00"),
                  currency: "BRL",
                  idempotency_key: "idem-qitech-destination-mismatch",
                  metadata: { "payout_kind" => "EXCESS" }
                )
              end

              assert_equal "qitech_target_taxpayer_mismatch", error.code
            end
          end
        end

        test "requires destination account for EXCESS payout" do
          with_tenant_db_context(tenant_id: @tenant.id) do
            supplier = Party.create!(
              tenant: @tenant,
              kind: "SUPPLIER",
              legal_name: "Fornecedor Sem Conta Destino",
              document_number: valid_cnpj_from_seed("qitech-destination-missing")
            )

            escrow_account = EscrowAccount.create!(
              tenant: @tenant,
              party: supplier,
              provider: "QITECH",
              account_type: "ESCROW",
              status: "ACTIVE",
              provider_account_id: "escrow-account-789",
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

            provider = QiTech.new(client: FakeClient.new)

            with_environment("QITECH_SOURCE_ACCOUNT_KEY" => "source-account-key") do
              error = assert_raises(Integrations::Escrow::ValidationError) do
                provider.create_payout!(
                  tenant_id: @tenant.id,
                  escrow_account: escrow_account,
                  recipient_party: supplier,
                  amount: BigDecimal("10.00"),
                  currency: "BRL",
                  idempotency_key: "idem-qitech-destination-missing",
                  metadata: { "payout_kind" => "EXCESS" }
                )
              end

              assert_equal "qitech_payout_destination_account_missing", error.code
            end
          end
        end

        private

        def with_environment(values)
          previous = values.to_h { |key, _value| [ key, ENV[key] ] }
          values.each { |key, value| ENV[key] = value }
          yield
        ensure
          previous.each { |key, value| ENV[key] = value }
        end

        class FakeClient
          attr_reader :last_path, :last_body

          def post(path:, body:)
            @last_path = path
            @last_body = body
            {
              "status" => "SENT",
              "end_to_end_id" => "e2e-123"
            }
          end
        end
      end
    end
  end
end
