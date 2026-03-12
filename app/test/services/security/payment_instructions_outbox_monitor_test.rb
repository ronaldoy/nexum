require "test_helper"

module Security
  class PaymentInstructionsOutboxMonitorTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @cache = ActiveSupport::Cache::MemoryStore.new
    end

    test "returns ok readiness when monitor is disabled" do
      with_environment("SECURITY_PAYMENT_INSTRUCTIONS_MONITOR_ENABLED" => "false") do
        assert_equal "ok", PaymentInstructionsOutboxMonitor.readiness_status(now: Time.utc(2026, 3, 12, 12, 0, 0), cache: @cache)
      end
    end

    test "returns error readiness when stale or dead-letter payment instruction events exist" do
      now = Time.utc(2026, 3, 12, 12, 0, 0)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        insert_outbox_event!(
          tenant_id: @tenant.id,
          event_type: "RECEIVABLE_ESCROW_PAYMENT_INSTRUCTIONS_REFRESH_REQUESTED",
          idempotency_key: "monitor-stale-event-001",
          created_at: now - 20.minutes,
          payload: {
            "receivable_id" => SecureRandom.uuid,
            "receivable_allocation_id" => SecureRandom.uuid,
            "operational_party_id" => SecureRandom.uuid,
            "provider" => "STARKBANK",
            "payment_instruction_idempotency_key" => "party-monitor-stale:escrow_account"
          }
        )
      end

      with_environment(
        "SECURITY_PAYMENT_INSTRUCTIONS_MONITOR_ENABLED" => "true",
        "SECURITY_PAYMENT_INSTRUCTIONS_STALE_AFTER_SECONDS" => "300",
        "SECURITY_PAYMENT_INSTRUCTIONS_STALE_THRESHOLD" => "1",
        "SECURITY_PAYMENT_INSTRUCTIONS_DEAD_LETTER_THRESHOLD" => "1"
      ) do
        assert_equal "error", PaymentInstructionsOutboxMonitor.readiness_status(now:, cache: @cache, report: false)
      end
    end

    test "emits one alert per window when backlog threshold is crossed" do
      now = Time.utc(2026, 3, 12, 12, 0, 0)
      notifications = []

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        event_id = insert_outbox_event!(
          tenant_id: @tenant.id,
          event_type: "RECEIVABLE_HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_REQUESTED",
          idempotency_key: "monitor-dead-letter-event-001",
          created_at: now - 10.minutes,
          payload: {
            "receivable_id" => SecureRandom.uuid,
            "receivable_allocation_id" => SecureRandom.uuid,
            "hospital_party_id" => SecureRandom.uuid,
            "operational_party_id" => SecureRandom.uuid,
            "provider" => "STARKBANK",
            "payment_instruction_idempotency_key" => "party-monitor-dead-letter:escrow_account",
            "hospital_sync_idempotency_key" => "monitor-dead-letter-event-001"
          }
        )
        OutboxDispatchAttempt.create!(
          tenant_id: @tenant.id,
          outbox_event_id: event_id,
          attempt_number: 1,
          status: "DEAD_LETTER",
          error_code: "hospital_api_unreachable",
          error_message: "Hospital API endpoint is unreachable.",
          occurred_at: now - 9.minutes
        )
      end

      with_environment(
        "SECURITY_PAYMENT_INSTRUCTIONS_MONITOR_ENABLED" => "true",
        "SECURITY_PAYMENT_INSTRUCTIONS_STALE_THRESHOLD" => "1",
        "SECURITY_PAYMENT_INSTRUCTIONS_DEAD_LETTER_THRESHOLD" => "1"
      ) do
        ActiveSupport::Notifications.subscribed(
          ->(_name, _start, _finish, _id, payload) { notifications << payload },
          PaymentInstructionsOutboxMonitor::ALERT_EVENT_NAME
        ) do
          2.times do
            PaymentInstructionsOutboxMonitor.readiness_status(now:, cache: @cache, report: true)
          end
        end
      end

      assert_equal 1, notifications.size
      assert_equal "payment_instruction_outbox_backlog", notifications.first.fetch(:alert_type)
    end

    private

    def insert_outbox_event!(tenant_id:, event_type:, idempotency_key:, created_at:, payload:)
      connection = ActiveRecord::Base.connection
      event_id = SecureRandom.uuid
      normalized_payload = payload.deep_stringify_keys
      normalized_payload["payload_hash"] = CanonicalJson.digest(normalized_payload)

      connection.execute(<<~SQL)
        INSERT INTO outbox_events (
          id, tenant_id, aggregate_type, aggregate_id, event_type, status, attempts, idempotency_key, payload, created_at, updated_at
        ) VALUES (
          #{connection.quote(event_id)},
          #{connection.quote(tenant_id)},
          'Receivable',
          #{connection.quote(SecureRandom.uuid)},
          #{connection.quote(event_type)},
          'PENDING',
          0,
          #{connection.quote(idempotency_key)},
          #{connection.quote(JSON.generate(normalized_payload))}::jsonb,
          #{connection.quote(created_at)},
          #{connection.quote(created_at)}
        )
      SQL

      event_id
    end

    def with_environment(overrides)
      previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
      overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      Rails.cache.clear
      PaymentInstructionsOutboxMonitor.reset_for_test!
    end
  end
end
