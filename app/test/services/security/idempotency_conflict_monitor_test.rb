require "test_helper"

module Security
  class IdempotencyConflictMonitorTest < ActiveSupport::TestCase
    setup do
      @cache = ActiveSupport::Cache::MemoryStore.new
    end

    test "returns ok readiness when monitor is disabled" do
      with_environment("SECURITY_IDEMPOTENCY_MONITOR_ENABLED" => "false") do
        assert_equal "ok", IdempotencyConflictMonitor.readiness_status(now: Time.utc(2026, 2, 22, 12, 0, 0), cache: @cache)
      end
    end

    test "returns error readiness when threshold is exceeded inside the rolling window" do
      now = Time.utc(2026, 2, 22, 12, 0, 0)

      with_environment(
        "SECURITY_IDEMPOTENCY_MONITOR_ENABLED" => "true",
        "SECURITY_IDEMPOTENCY_CONFLICT_THRESHOLD" => "2",
        "SECURITY_IDEMPOTENCY_CONFLICT_WINDOW_SECONDS" => "300"
      ) do
        3.times do
          IdempotencyConflictMonitor.record_conflict!(
            payload: { service: "Security::IdempotencyConflictMonitorTest", tenant_id: "tenant-test" },
            occurred_at: now,
            cache: @cache
          )
        end

        assert_equal 3, IdempotencyConflictMonitor.rolling_conflict_count(now:, cache: @cache)
        assert_equal "error", IdempotencyConflictMonitor.readiness_status(now:, cache: @cache)
      end
    end

    test "ignores buckets that are outside the configured rolling window" do
      now = Time.utc(2026, 2, 22, 12, 0, 0)

      with_environment(
        "SECURITY_IDEMPOTENCY_MONITOR_ENABLED" => "true",
        "SECURITY_IDEMPOTENCY_CONFLICT_THRESHOLD" => "1",
        "SECURITY_IDEMPOTENCY_CONFLICT_WINDOW_SECONDS" => "60"
      ) do
        IdempotencyConflictMonitor.record_conflict!(
          payload: { service: "Security::IdempotencyConflictMonitorTest", tenant_id: "tenant-test" },
          occurred_at: now - 120.seconds,
          cache: @cache
        )
        IdempotencyConflictMonitor.record_conflict!(
          payload: { service: "Security::IdempotencyConflictMonitorTest", tenant_id: "tenant-test" },
          occurred_at: now,
          cache: @cache
        )

        assert_equal 1, IdempotencyConflictMonitor.rolling_conflict_count(now:, cache: @cache)
        assert_equal "ok", IdempotencyConflictMonitor.readiness_status(now:, cache: @cache)
      end
    end

    test "emits one security alert per rolling window when threshold is crossed" do
      now = Time.utc(2026, 2, 22, 12, 0, 0)
      notifications = []

      with_environment(
        "SECURITY_IDEMPOTENCY_MONITOR_ENABLED" => "true",
        "SECURITY_IDEMPOTENCY_CONFLICT_THRESHOLD" => "1",
        "SECURITY_IDEMPOTENCY_CONFLICT_WINDOW_SECONDS" => "300"
      ) do
        ActiveSupport::Notifications.subscribed(
          ->(_name, _start, _finish, _id, payload) { notifications << payload },
          Security::IdempotencyConflictMonitor::ALERT_EVENT_NAME
        ) do
          3.times do
            IdempotencyConflictMonitor.record_conflict!(
              payload: { service: "Security::IdempotencyConflictMonitorTest", tenant_id: "tenant-test" },
              occurred_at: now,
              cache: @cache
            )
          end
        end
      end

      assert_equal 1, notifications.size
      assert_equal "idempotency_conflict_spike", notifications.first.fetch(:alert_type)
    end

    private

    def with_environment(overrides)
      previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
      overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end
end
