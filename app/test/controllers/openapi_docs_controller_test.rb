require "test_helper"

class OpenapiDocsControllerTest < ActionDispatch::IntegrationTest
  test "serves openapi v1 yaml from docs directory" do
    get "/docs/openapi/v1"

    assert_response :success
    assert_equal "application/yaml", response.media_type
    assert_includes response.body, "openapi: 3.1.0"
    assert_includes response.body, "title: Nexum API"
  end
end
