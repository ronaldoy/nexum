module Integrations
  module Escrow
    module StarkBank
      class AllocateBatch
        def initialize(tenant_id:, provider:, source_provider_account_id:, amount:, risk_limit_amount:, balance_amount:)
          @tenant_id = tenant_id
          @provider = provider
          @source_provider_account_id = source_provider_account_id
          @amount = amount.to_d
          @risk_limit_amount = risk_limit_amount.to_d
          @balance_amount = balance_amount.to_d
        end

        def call
          ActiveRecord::Base.transaction do
            advisory_lock!
            batch = open_batch
            return reserve_batch!(batch) if batch && batch_can_dispatch?(batch)

            close_batch!(batch) if batch.present?

            dispatch_budget = [ @risk_limit_amount, @balance_amount ].min
            if dispatch_budget < @amount || dispatch_budget <= 0
              raise ValidationError.new(
                code: "starkbank_insufficient_dispatch_budget",
                message: "Stark Bank funding is insufficient for the next payout batch.",
                details: {
                  requested_amount: @amount.to_s("F"),
                  risk_limit_amount: @risk_limit_amount.to_s("F"),
                  balance_amount: @balance_amount.to_s("F")
                }
              )
            end

            now = Time.current
            batch = EscrowPayoutBatch.create!(
              tenant_id: @tenant_id,
              provider: @provider,
              status: "OPEN",
              source_provider_account_id: @source_provider_account_id,
              risk_limit_amount: @risk_limit_amount,
              balance_snapshot_amount: dispatch_budget,
              reserved_amount: @amount,
              dispatched_amount: "0.00",
              fee_amount: "0.00",
              started_at: now,
              last_polled_at: now,
              metadata: {
                "balance_snapshot_amount" => dispatch_budget.to_s("F")
              }
            )
            close_batch_if_exhausted!(batch)
            batch
          end
        end

        private

        def open_batch
          EscrowPayoutBatch
            .lock
            .open_batches
            .where(
              tenant_id: @tenant_id,
              provider: @provider,
              source_provider_account_id: @source_provider_account_id
            )
            .order(started_at: :desc, created_at: :desc)
            .first
        end

        def batch_can_dispatch?(batch)
          batch.remaining_capacity >= @amount && batch.available_snapshot_budget >= @amount
        end

        def close_batch!(batch)
          return if batch.status == "CLOSED"

          batch.update!(
            status: "CLOSED",
            closed_at: batch.closed_at || Time.current,
            last_polled_at: Time.current
          )
        end

        def reserve_batch!(batch)
          batch.reserved_amount = batch.reserved_amount.to_d + @amount
          batch.last_polled_at = Time.current
          close_batch_if_exhausted!(batch)
          batch.save!
          batch
        end

        def close_batch_if_exhausted!(batch)
          return unless batch.reserved_amount.to_d >= batch.risk_limit_amount.to_d || batch.reserved_amount.to_d >= batch.balance_snapshot_amount.to_d

          batch.status = "CLOSED"
          batch.closed_at ||= Time.current
        end

        def advisory_lock!
          key = [ @tenant_id, @provider, @source_provider_account_id, Date.current.iso8601 ].join(":")
          quoted_key = ActiveRecord::Base.connection.quote(key)
          ActiveRecord::Base.connection.execute(
            "SELECT pg_advisory_xact_lock(hashtext('starkbank_payout_batch'), hashtext(#{quoted_key}))"
          )
        end
      end
    end
  end
end
