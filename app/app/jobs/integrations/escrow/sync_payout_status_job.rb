module Integrations
  module Escrow
    class SyncPayoutStatusJob < ApplicationJob
      include TenantDatabaseContext

      queue_as :default

      retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 5
      retry_on Integrations::Escrow::RemoteError, wait: :polynomially_longer, attempts: 10

      def perform(tenant_id:, payout_id:)
        result = nil

        with_tenant_database_context(tenant_id: tenant_id, role: "worker") do
          result = Integrations::Escrow::SyncPayoutStatus.new.call(payout_id: payout_id)
        end

        return unless result&.reschedule?

        self.class.set(wait_until: result.reschedule_at).perform_later(tenant_id:, payout_id:)
      end
    end
  end
end
