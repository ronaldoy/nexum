module Integrations
  module Escrow
    class SyncPayoutStatus
      BASE_WAIT_SECONDS = 30
      MAX_WAIT_SECONDS = 10.minutes.to_i

      Result = Struct.new(:status, :reschedule_at, keyword_init: true) do
        def reschedule?
          reschedule_at.present?
        end
      end

      def initialize(clock: -> { Time.current })
        @clock = clock
      end

      def call(payout_id:)
        payout = EscrowPayout.includes(:escrow_account).find(payout_id)
        return Result.new(status: "noop") unless payout.status == "PROCESSING"

        provider = ProviderRegistry.fetch(provider_code: payout.provider, tenant_id: payout.tenant_id)
        return Result.new(status: "noop") unless provider.respond_to?(:fetch_payout!)

        payout_result = provider.fetch_payout!(tenant_id: payout.tenant_id, payout: payout)
        apply_result!(payout:, payout_result:)

        if payout.reload.status == "PROCESSING"
          return Result.new(
            status: "processing",
            reschedule_at: @clock.call + next_wait_seconds(payout).seconds
          )
        end

        Result.new(status: payout.status.downcase)
      end

      private

      def apply_result!(payout:, payout_result:)
        payout.with_lock do
          metadata = (payout.metadata || {}).deep_dup
          sync_metadata = metadata.fetch("status_sync", {})
          sync_metadata["attempts"] = sync_metadata.fetch("attempts", 0).to_i + 1
          sync_metadata["last_synced_at"] = @clock.call.iso8601(6)
          sync_metadata["provider_status"] = payout_result.provider_status

          metadata["status_sync"] = sync_metadata

          payout.update!(
            status: payout_result.status,
            processed_at: payout_result.status.in?(%w[SENT FAILED]) ? @clock.call : payout.processed_at,
            provider_status: payout_result.provider_status,
            provider_fee_amount: payout_result.provider_fee_amount.to_d,
            provider_fee_currency: payout_result.provider_fee_currency.to_s.presence || "BRL",
            provider_end_to_end_id: payout_result.provider_end_to_end_id,
            confirmed_at: payout_result.confirmed_at,
            last_error_code: payout_result.status == "FAILED" ? "starkbank_transfer_failed" : nil,
            last_error_message: payout_result.status == "FAILED" ? "Stark Bank PIX transfer failed." : nil,
            metadata: payout_result.metadata.present? ? metadata.merge("provider_result" => payout_result.metadata) : metadata
          )
        end
      end

      def next_wait_seconds(payout)
        attempts = payout.metadata&.dig("status_sync", "attempts").to_i
        [ BASE_WAIT_SECONDS * (attempts + 1), MAX_WAIT_SECONDS ].min
      end
    end
  end
end
