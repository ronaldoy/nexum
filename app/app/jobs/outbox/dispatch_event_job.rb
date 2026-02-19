module Outbox
  class DispatchEventJob < ApplicationJob
    include TenantDatabaseContext

    queue_as :default

    retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 5

    def perform(tenant_id:, outbox_event_id:)
      result = nil

      with_tenant_database_context(tenant_id: tenant_id, role: "worker") do
        result = Outbox::DispatchEvent.new.call(outbox_event_id: outbox_event_id)
      end

      return unless result&.retry_scheduled?
      return if result.next_attempt_at.blank?

      self.class
        .set(wait_until: result.next_attempt_at)
        .perform_later(tenant_id: tenant_id, outbox_event_id: outbox_event_id)
    end
  end
end
