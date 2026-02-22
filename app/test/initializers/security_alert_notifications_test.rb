require "test_helper"

class SecurityAlertNotificationsTest < ActiveSupport::TestCase
  test "reports corrected alert.security notifications" do
    reports = []
    reporter = Rails.error
    original_report_method = reporter.method(:report)

    reporter.define_singleton_method(:report) do |error, **options|
      reports << { error: error, options: options }
    end

    begin
      ActiveSupport::Notifications.instrument(
        Security::IdempotencyConflictMonitor::ALERT_EVENT_NAME,
        alert_type: "idempotency_conflict_spike",
        severity: "warning",
        tenant_id: "tenant-test",
        service: "Security::IdempotencyConflictMonitor"
      )
    ensure
      reporter.define_singleton_method(:report, original_report_method)
    end

    report = reports.last
    assert report.present?
    assert_equal "Security::AlertNotificationError", report.fetch(:error).class.name
    assert_equal "warning", report.dig(:options, :context, "severity")
    assert_equal Security::IdempotencyConflictMonitor::ALERT_EVENT_NAME, report.dig(:options, :context, "event_name")
  end

  test "reports legacy security.alert notifications for backward compatibility" do
    reports = []
    reporter = Rails.error
    original_report_method = reporter.method(:report)

    reporter.define_singleton_method(:report) do |error, **options|
      reports << { error: error, options: options }
    end

    begin
      ActiveSupport::Notifications.instrument(
        "security.alert",
        alert_type: "legacy_alert",
        severity: "warning",
        tenant_id: "tenant-test",
        service: "LegacyEmitter"
      )
    ensure
      reporter.define_singleton_method(:report, original_report_method)
    end

    report = reports.last
    assert report.present?
    assert_equal "legacy_alert", report.dig(:options, :context, "alert_type")
    assert_equal "security.alert", report.dig(:options, :context, "event_name")
  end
end
