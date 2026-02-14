require "test_helper"

class ActiveStorage::DirectUploadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default)
    @user = users(:one)
    @token = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      @user.update!(role: "ops_admin")
      _, @token = ApiAccessToken.issue!(
        tenant: @tenant,
        user: @user,
        name: "Direct Upload",
        scopes: %w[receivables:documents:write]
      )
    end
  end

  test "rejects unauthenticated direct upload creation" do
    post rails_direct_uploads_path, params: valid_blob_payload, as: :json

    assert_response :unauthorized
    assert_equal "invalid_token", response.parsed_body.dig("error", "code")
  end

  test "creates direct upload with bearer token and tenant metadata" do
    post rails_direct_uploads_path,
      headers: { "Authorization" => "Bearer #{@token}" },
      params: valid_blob_payload,
      as: :json

    assert_response :success
    signed_id = response.parsed_body["signed_id"]
    blob = ActiveStorage::Blob.find_signed!(signed_id)
    assert_equal @tenant.id.to_s, blob.metadata["tenant_id"]
  end

  test "rejects oversized direct uploads" do
    oversized = valid_blob_payload.deep_dup
    oversized[:blob][:byte_size] = 50.megabytes

    post rails_direct_uploads_path,
      headers: { "Authorization" => "Bearer #{@token}" },
      params: oversized,
      as: :json

    assert_response :content_too_large
    assert_equal "file_too_large", response.parsed_body.dig("error", "code")
  end

  private

  def valid_blob_payload
    {
      blob: {
        filename: "contract.pdf",
        byte_size: 1024,
        checksum: Base64.strict_encode64(Digest::MD5.digest("content")),
        content_type: "application/pdf",
        metadata: {}
      }
    }
  end
end
