require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
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
    assert body["timestamp"].present?
  end
end
