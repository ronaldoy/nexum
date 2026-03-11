require "test_helper"

class BrowserSecurityHeadersTest < ActionDispatch::IntegrationTest
  test "session entrypoint sends hardened browser headers" do
    get new_session_path

    assert_response :success
    assert_equal "same-origin", response.headers["Cross-Origin-Opener-Policy"]
    assert_equal "same-origin", response.headers["Cross-Origin-Resource-Policy"]
    assert_equal "?1", response.headers["Origin-Agent-Cluster"]
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "DENY", response.headers["X-Frame-Options"]
    assert_equal "none", response.headers["X-Permitted-Cross-Domain-Policies"]
    assert_includes response.headers["Content-Security-Policy"].to_s, "frame-ancestors 'none'"
  end
end
