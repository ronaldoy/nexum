require "test_helper"

class CspReportsControllerTest < ActionDispatch::IntegrationTest
  test "accepts csp report payload" do
    post "/security/csp_reports",
      params: {
        "csp-report" => {
          "blocked-uri" => "https://evil.example",
          "violated-directive" => "script-src"
        }
      }.to_json,
      headers: { "CONTENT_TYPE" => "application/csp-report" }

    assert_response :no_content
  end
end
