ActiveSupport::Notifications.subscribe("idempotency.conflict") do |_name, _start, _finish, _id, payload|
  Security::IdempotencyConflictMonitor.record_conflict!(payload: payload)
end
