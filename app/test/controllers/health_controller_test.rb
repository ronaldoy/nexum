require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    Security::IdempotencyConflictMonitor.reset_for_test!
  end

  teardown do
    Rails.cache.clear
    Security::IdempotencyConflictMonitor.reset_for_test!
  end

  test "health returns liveness response" do
    get "/health"

    assert_response :success
    body = response.parsed_body
    assert_equal "ok", body["status"]
    assert_equal({}, body["checks"])
    assert body["timestamp"].present?
  end

  test "ready returns readiness response" do
    get "/ready"

    assert_response :success
    body = response.parsed_body
    assert_equal "ok", body["status"]
    assert body["checks"].is_a?(Hash)
    assert_equal "ok", body.dig("checks", "primary")
    assert_equal "ok", body.dig("checks", "database_role")
    assert_equal "ok", body.dig("checks", "idempotency_conflicts")
    assert body["timestamp"].present?
  end

  test "ready returns service unavailable when idempotency conflicts exceed threshold" do
    with_environment(
      "SECURITY_IDEMPOTENCY_MONITOR_ENABLED" => "true",
      "SECURITY_IDEMPOTENCY_CONFLICT_THRESHOLD" => "1",
      "SECURITY_IDEMPOTENCY_CONFLICT_WINDOW_SECONDS" => "300"
    ) do
      Security::IdempotencyConflictMonitor.record_conflict!(payload: { service: "HealthControllerTest", tenant_id: "tenant-a" })
      Security::IdempotencyConflictMonitor.record_conflict!(payload: { service: "HealthControllerTest", tenant_id: "tenant-a" })

      get "/ready"

      assert_response :service_unavailable
      body = response.parsed_body
      assert_equal "error", body["status"]
      assert_equal "error", body.dig("checks", "idempotency_conflicts")
    end
  end

  test "ready returns service unavailable when database role security check fails" do
    original_method = Security::DatabaseRoleGuard.method(:readiness_status)
    Security::DatabaseRoleGuard.singleton_class.define_method(:readiness_status) { |**| "error" }

    begin
      get "/ready"

      assert_response :service_unavailable
      body = response.parsed_body
      assert_equal "error", body["status"]
      assert_equal "error", body.dig("checks", "database_role")
    ensure
      Security::DatabaseRoleGuard.singleton_class.define_method(:readiness_status, original_method)
    end
  end

  private

  def with_environment(overrides)
    previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rails.cache.clear
    Security::IdempotencyConflictMonitor.reset_for_test!
  end
end
