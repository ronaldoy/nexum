require "test_helper"

module Outbox
  class DispatchEventTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @user = users(:one)
    end

    test "records sent dispatch attempt for a deliverable event" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        outbox_event = create_outbox_event!

        result = Outbox::DispatchEvent.new.call(outbox_event_id: outbox_event.id)

        assert_equal "SENT", result.status
        assert_equal 1, result.attempt_number
        assert_equal false, result.skipped?

        attempts = OutboxDispatchAttempt.where(tenant_id: @tenant.id, outbox_event_id: outbox_event.id).order(:attempt_number).to_a
        assert_equal 1, attempts.size
        assert_equal "SENT", attempts.first.status
        assert_nil attempts.first.next_attempt_at

        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "OUTBOX_EVENT_DISPATCHED",
          target_type: "OutboxEvent",
          target_id: outbox_event.id
        ).count
      end
    end

    test "schedules retry and then marks dead letter after max attempts" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
        outbox_event = create_outbox_event!(payload: { "simulate_dispatch_failure" => true })
        dispatcher = Outbox::DispatchEvent.new(
          max_attempts: 2,
          backoff_strategy: ->(_attempt_number) { 0 }
        )

        first = dispatcher.call(outbox_event_id: outbox_event.id)
        assert_equal "RETRY_SCHEDULED", first.status
        assert_equal 1, first.attempt_number
        assert first.next_attempt_at.present?

        second = dispatcher.call(outbox_event_id: outbox_event.id)
        assert_equal "DEAD_LETTER", second.status
        assert_equal 2, second.attempt_number

        third = dispatcher.call(outbox_event_id: outbox_event.id)
        assert_equal true, third.skipped?
        assert_equal "already_terminal", third.reason

        attempts = OutboxDispatchAttempt.where(tenant_id: @tenant.id, outbox_event_id: outbox_event.id).order(:attempt_number).to_a
        assert_equal 2, attempts.size
        assert_equal "RETRY_SCHEDULED", attempts.first.status
        assert_equal "DEAD_LETTER", attempts.second.status

        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "OUTBOX_EVENT_RETRY_SCHEDULED",
          target_type: "OutboxEvent",
          target_id: outbox_event.id
        ).count
        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "OUTBOX_EVENT_DEAD_LETTERED",
          target_type: "OutboxEvent",
          target_id: outbox_event.id
        ).count
      end
    end

    private

    def create_outbox_event!(payload: {})
      OutboxEvent.create!(
        tenant: @tenant,
        aggregate_type: "AnticipationRequest",
        aggregate_id: SecureRandom.uuid,
        event_type: "AUTH_CHALLENGE_EMAIL_DISPATCH_REQUESTED",
        status: "PENDING",
        payload: payload
      )
    end
  end
end
