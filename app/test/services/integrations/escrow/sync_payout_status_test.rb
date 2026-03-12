require "test_helper"

module Integrations
  module Escrow
    class SyncPayoutStatusTest < ActiveSupport::TestCase
      setup do
        @tenant = tenants(:default)
        @user = users(:one)
        @clock_time = Time.zone.parse("2026-03-12 12:00:00")
      end

      test "keeps processing payout in flight and schedules another poll" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          payout = create_processing_payout!(suffix: "sync-processing")
          provider = FakeFetchProvider.new(
            Integrations::Escrow::PayoutResult.new(
              provider_transfer_id: payout.provider_transfer_id,
              status: "PROCESSING",
              provider_status: "processing",
              provider_fee_amount: BigDecimal("0.75"),
              provider_fee_currency: "BRL",
              provider_end_to_end_id: nil,
              confirmed_at: nil,
              metadata: { "transfer" => { "status" => "processing" } }
            )
          )

          result = nil
          with_stubbed_provider(provider) do
            result = Integrations::Escrow::SyncPayoutStatus.new(clock: -> { @clock_time }).call(payout_id: payout.id)
          end

          payout.reload
          assert_equal "processing", result.status
          assert_equal @clock_time + 60.seconds, result.reschedule_at
          assert_equal "PROCESSING", payout.status
          assert_equal "processing", payout.provider_status
          assert_equal BigDecimal("0.75"), payout.provider_fee_amount.to_d
          assert_equal 1, payout.metadata.dig("status_sync", "attempts")
          assert_equal "processing", payout.metadata.dig("status_sync", "provider_status")
          assert_equal "processing", payout.metadata.dig("provider_result", "transfer", "status")
        end
      end

      test "marks payout as sent when provider confirms the pix transfer" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          payout = create_processing_payout!(
            suffix: "sync-sent",
            metadata: { "status_sync" => { "attempts" => 1 } }
          )
          provider = FakeFetchProvider.new(
            Integrations::Escrow::PayoutResult.new(
              provider_transfer_id: payout.provider_transfer_id,
              status: "SENT",
              provider_status: "success",
              provider_fee_amount: BigDecimal("1.10"),
              provider_fee_currency: "BRL",
              provider_end_to_end_id: "E2E-SYNC-123",
              confirmed_at: @clock_time,
              metadata: { "transfer" => { "status" => "success" } }
            )
          )

          result = nil
          with_stubbed_provider(provider) do
            result = Integrations::Escrow::SyncPayoutStatus.new(clock: -> { @clock_time }).call(payout_id: payout.id)
          end

          payout.reload
          assert_equal "sent", result.status
          assert_nil result.reschedule_at
          assert_equal "SENT", payout.status
          assert_equal @clock_time, payout.processed_at
          assert_equal @clock_time, payout.confirmed_at
          assert_equal "E2E-SYNC-123", payout.provider_end_to_end_id
          assert_equal BigDecimal("1.10"), payout.provider_fee_amount.to_d
          assert_nil payout.last_error_code
          assert_nil payout.last_error_message
        end
      end

      private

      def create_processing_payout!(suffix:, metadata: {})
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
        receivable_kind = ReceivableKind.create!(
          tenant: @tenant,
          code: "supplier_invoice_sync_#{suffix}",
          name: "Supplier Invoice Sync #{suffix}",
          source_family: "SUPPLIER"
        )
        receivable = Receivable.create!(
          tenant: @tenant,
          receivable_kind: receivable_kind,
          debtor_party: hospital,
          creditor_party: supplier,
          beneficiary_party: supplier,
          external_reference: "SYNC-#{suffix.upcase}",
          gross_amount: "100.00",
          currency: "BRL",
          performed_at: @clock_time - 2.days,
          due_at: @clock_time + 5.days,
          cutoff_at: BusinessCalendar.cutoff_at((@clock_time - 1.day).to_date)
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
          fidc_amount: "5.00",
          beneficiary_amount: "95.00",
          fidc_balance_before: "5.00",
          fidc_balance_after: "0.00",
          paid_at: @clock_time - 10.minutes,
          payment_reference: "payment-ref-#{suffix}",
          idempotency_key: "settlement-#{suffix}",
          request_id: SecureRandom.uuid,
          metadata: {}
        )
        escrow_account = EscrowAccount.create!(
          tenant: @tenant,
          party: supplier,
          provider: "STARKBANK",
          account_type: "ESCROW",
          status: "ACTIVE",
          provider_account_id: "workspace-#{suffix}",
          provider_request_id: "workspace-request-#{suffix}",
          last_synced_at: @clock_time,
          metadata: {}
        )

        EscrowPayout.create!(
          tenant: @tenant,
          party: supplier,
          receivable_payment_settlement: settlement,
          escrow_account: escrow_account,
          provider: "STARKBANK",
          status: "PROCESSING",
          amount: "95.00",
          currency: "BRL",
          idempotency_key: "sync-payout-#{suffix}",
          provider_transfer_id: "provider-transfer-#{suffix}",
          provider_status: "created",
          provider_fee_amount: "0.00",
          provider_fee_currency: "BRL",
          requested_at: @clock_time - 5.minutes,
          metadata: metadata
        )
      end

      def with_stubbed_provider(provider)
        singleton = Integrations::Escrow::ProviderRegistry.singleton_class
        original_method = singleton.instance_method(:fetch)
        singleton.define_method(:fetch) { |provider_code:, tenant_id: nil, tenant_slug: nil| provider }
        yield
      ensure
        singleton.define_method(:fetch, original_method) if original_method
      end

      class FakeFetchProvider
        def initialize(result)
          @result = result
        end

        def fetch_payout!(tenant_id:, payout:)
          @result
        end
      end
    end
  end
end
