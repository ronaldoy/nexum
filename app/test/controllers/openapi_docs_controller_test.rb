require "test_helper"

class OpenapiDocsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_token = ENV["OPENAPI_DOCS_TOKEN"]
    @docs_token = "test-openapi-docs-token"
    ENV["OPENAPI_DOCS_TOKEN"] = @docs_token
  end

  teardown do
    ENV["OPENAPI_DOCS_TOKEN"] = @original_token
  end

  test "serves openapi v1 yaml from docs directory" do
    get "/docs/openapi/v1", headers: authorization_header(@docs_token)

    assert_response :success
    assert_equal "application/yaml", response.media_type
    assert_includes response.body, "openapi: 3.1.0"
    assert_includes response.body, "title: Nexum API"
  end

  test "returns unauthorized without bearer token" do
    get "/docs/openapi/v1"

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  test "returns unauthorized with invalid bearer token" do
    get "/docs/openapi/v1", headers: authorization_header("invalid")

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  private

  def authorization_header(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
