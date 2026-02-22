module Security
  class AlertNotificationError < StandardError; end
end

primary_security_alert_event_name =
  if defined?(Security::IdempotencyConflictMonitor::ALERT_EVENT_NAME)
    Security::IdempotencyConflictMonitor::ALERT_EVENT_NAME
  else
    "alert.security"
  end

SECURITY_ALERT_EVENT_NAMES = [
  primary_security_alert_event_name,
  "security.alert" # Backward-compatible alias for older instrumentation.
].uniq.freeze

SECURITY_ALERT_EVENT_NAMES.each do |event_name|
  ActiveSupport::Notifications.subscribe(event_name) do |name, _start, _finish, _id, payload|
    normalized_payload = payload.to_h.each_with_object({}) do |(key, value), output|
      output[key.to_s] = value
    end

    Rails.logger.error(
      "security_alert_notification " \
        "event_name=#{name} " \
        "alert_type=#{normalized_payload["alert_type"]} " \
        "severity=#{normalized_payload["severity"]} " \
        "tenant_id=#{normalized_payload["tenant_id"]} " \
        "service=#{normalized_payload["service"]}"
    )

    Rails.error.report(
      Security::AlertNotificationError.new("Security alert triggered: #{normalized_payload["alert_type"] || "unknown"}"),
      handled: true,
      severity: :warning,
      context: normalized_payload.merge("event_name" => name)
    )
  rescue StandardError => error
    Rails.logger.error("security_alert_notification_error event_name=#{name} error_class=#{error.class} message=#{error.message}")
  end
end
