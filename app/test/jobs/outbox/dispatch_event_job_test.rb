require "test_helper"

module Outbox
  class DispatchEventJobTest < ActiveJob::TestCase
    setup do
      @tenant = tenants(:default)
      @user = users(:one)
    end

    test "dispatches outbox event within tenant database context" do
      outbox_event = nil

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        outbox_event = OutboxEvent.create!(
          tenant: @tenant,
          aggregate_type: "AnticipationRequest",
          aggregate_id: SecureRandom.uuid,
          event_type: "AUTH_CHALLENGE_EMAIL_DISPATCH_REQUESTED",
          status: "PENDING",
          payload: {}
        )
      end

      clear_enqueued_jobs
      clear_performed_jobs

      Outbox::DispatchEventJob.perform_now(
        tenant_id: @tenant.id,
        outbox_event_id: outbox_event.id
      )

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        attempt = OutboxDispatchAttempt.find_by!(
          tenant_id: @tenant.id,
          outbox_event_id: outbox_event.id,
          attempt_number: 1
        )
        assert_equal "SENT", attempt.status
      end
    end
  end
end
