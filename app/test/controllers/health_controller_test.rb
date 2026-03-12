require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    Security::IdempotencyConflictMonitor.reset_for_test!
    Security::PaymentInstructionsOutboxMonitor.reset_for_test!
  end

  teardown do
    Rails.cache.clear
    Security::IdempotencyConflictMonitor.reset_for_test!
    Security::PaymentInstructionsOutboxMonitor.reset_for_test!
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
    assert_equal "ok", body.dig("checks", "database_schema")
    assert_equal "ok", body.dig("checks", "idempotency_conflicts")
    assert_equal "ok", body.dig("checks", "payment_instruction_outbox")
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

  test "ready returns service unavailable when database schema audit fails" do
    original_method = Security::DatabaseSchemaAudit.method(:readiness_status)
    Security::DatabaseSchemaAudit.singleton_class.define_method(:readiness_status) { |**| "error" }

    begin
      get "/ready"

      assert_response :service_unavailable
      body = response.parsed_body
      assert_equal "error", body["status"]
      assert_equal "error", body.dig("checks", "database_schema")
    ensure
      Security::DatabaseSchemaAudit.singleton_class.define_method(:readiness_status, original_method)
    end
  end

  test "ready returns service unavailable when payment instruction outbox monitor fails" do
    original_method = Security::PaymentInstructionsOutboxMonitor.method(:readiness_status)
    Security::PaymentInstructionsOutboxMonitor.singleton_class.define_method(:readiness_status) { |**| "error" }

    begin
      get "/ready"

      assert_response :service_unavailable
      body = response.parsed_body
      assert_equal "error", body["status"]
      assert_equal "error", body.dig("checks", "payment_instruction_outbox")
    ensure
      Security::PaymentInstructionsOutboxMonitor.singleton_class.define_method(:readiness_status, original_method)
    end
  end

  test "ready rejects remote probe without token" do
    with_stubbed_ready_probe_local_request(false) do
      get "/ready"
    end

    assert_response :not_found
  end

  test "ready accepts remote probe with configured token" do
    with_environment("READY_CHECK_TOKEN" => "probe-secret") do
      with_stubbed_ready_probe_local_request(false) do
        get "/ready", headers: { "X-Ready-Token" => "probe-secret" }
      end
    end

    assert_response :success
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
    Security::PaymentInstructionsOutboxMonitor.reset_for_test!
  end

  def with_stubbed_ready_probe_local_request(value)
    original_method = HealthController.instance_method(:ready_probe_local_request?)
    HealthController.send(:define_method, :ready_probe_local_request?) { value }
    yield
  ensure
    HealthController.send(:define_method, :ready_probe_local_request?, original_method)
  end
end
