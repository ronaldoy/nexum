require "test_helper"

class ActiveStorage::DirectUploadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default)
    @user = users(:one)
    @token = nil
    @secondary_token = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      @user.update!(role: "ops_admin")
      _, @token = ApiAccessToken.issue!(
        tenant: @tenant,
        user: @user,
        name: "Direct Upload",
        scopes: %w[receivables:documents:write]
      )

      secondary_user = User.create!(
        tenant: @tenant,
        email_address: "direct-upload-secondary@example.com",
        password: "password",
        password_confirmation: "password",
        role: "supplier_user"
      )
      _, @secondary_token = ApiAccessToken.issue!(
        tenant: @tenant,
        user: secondary_user,
        name: "Direct Upload Secondary",
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
      headers: authorization_headers("direct-upload-001"),
      params: valid_blob_payload,
      as: :json

    assert_response :success
    signed_id = response.parsed_body["signed_id"]
    blob = ActiveStorage::Blob.find_signed!(signed_id)
    assert_equal @tenant.id.to_s, blob.metadata["tenant_id"]
  end

  test "allows bearer token direct upload without csrf token when forgery protection is enabled" do
    with_forgery_protection do
      post rails_direct_uploads_path,
        headers: authorization_headers("direct-upload-csrf-bearer-001"),
        params: valid_blob_payload,
        as: :json
    end

    assert_response :success
  end

  test "rejects session-authenticated direct upload without csrf token when forgery protection is enabled" do
    sign_in_as(@user)

    with_forgery_protection do
      post rails_direct_uploads_path,
        headers: { "Idempotency-Key" => "direct-upload-csrf-session-001" },
        params: valid_blob_payload,
        as: :json
    end

    assert_response :unprocessable_entity
  end

  test "accepts session-authenticated direct upload with csrf token when forgery protection is enabled" do
    sign_in_as(@user)

    with_forgery_protection do
      get root_path
      csrf_token = response.body.match(/name="csrf-token" content="([^"]+)"/)&.captures&.first
      assert csrf_token.present?

      post rails_direct_uploads_path,
        headers: {
          "Idempotency-Key" => "direct-upload-csrf-session-valid-001",
          "X-CSRF-Token" => csrf_token
        },
        params: valid_blob_payload,
        as: :json
    end

    assert_response :success
  end

  test "overwrites spoofed tenant metadata on direct upload" do
    secondary_tenant = tenants(:secondary)
    payload = valid_blob_payload.deep_dup
    payload[:blob][:metadata] = {
      "tenant_id" => secondary_tenant.id.to_s,
      "actor_party_id" => "spoofed-actor"
    }

    post rails_direct_uploads_path,
      headers: authorization_headers("direct-upload-tenant-spoof-001"),
      params: payload,
      as: :json

    assert_response :success
    blob = ActiveStorage::Blob.find_signed!(response.parsed_body["signed_id"])
    assert_equal @tenant.id.to_s, blob.metadata["tenant_id"]
    refute_equal secondary_tenant.id.to_s, blob.metadata["tenant_id"]
  end

  test "rejects oversized direct uploads" do
    oversized = valid_blob_payload.deep_dup
    oversized[:blob][:byte_size] = 50.megabytes

    post rails_direct_uploads_path,
      headers: authorization_headers("direct-upload-oversized-001"),
      params: oversized,
      as: :json

    assert_response :content_too_large
    assert_equal "file_too_large", response.parsed_body.dig("error", "code")
  end

  test "requires idempotency key for direct uploads" do
    post rails_direct_uploads_path,
      headers: { "Authorization" => "Bearer #{@token}" },
      params: valid_blob_payload,
      as: :json

    assert_response :unprocessable_entity
    assert_equal "missing_idempotency_key", response.parsed_body.dig("error", "code")
  end

  test "replays direct upload creation with same idempotency key and payload" do
    post rails_direct_uploads_path,
      headers: authorization_headers("direct-upload-replay-001"),
      params: valid_blob_payload,
      as: :json
    assert_response :success
    first_signed_id = response.parsed_body["signed_id"]
    assert_equal false, response.parsed_body["replayed"]

    post rails_direct_uploads_path,
      headers: authorization_headers("direct-upload-replay-001"),
      params: valid_blob_payload,
      as: :json

    assert_response :success
    assert_equal true, response.parsed_body["replayed"]
    assert_equal first_signed_id, response.parsed_body["signed_id"]
  end

  test "rejects same idempotency key with different payload" do
    post rails_direct_uploads_path,
      headers: authorization_headers("direct-upload-conflict-001"),
      params: valid_blob_payload,
      as: :json
    assert_response :success

    changed_payload = valid_blob_payload.deep_dup
    changed_payload[:blob][:byte_size] = 2048

    post rails_direct_uploads_path,
      headers: authorization_headers("direct-upload-conflict-001"),
      params: changed_payload,
      as: :json

    assert_response :conflict
    assert_equal "idempotency_key_reused_with_different_payload", response.parsed_body.dig("error", "code")
  end

  test "allows same idempotency key for different authenticated actors" do
    post rails_direct_uploads_path,
      headers: authorization_headers("direct-upload-actor-scope-001"),
      params: valid_blob_payload,
      as: :json
    assert_response :success
    first_signed_id = response.parsed_body["signed_id"]

    post rails_direct_uploads_path,
      headers: {
        "Authorization" => "Bearer #{@secondary_token}",
        "Idempotency-Key" => "direct-upload-actor-scope-001"
      },
      params: valid_blob_payload,
      as: :json

    assert_response :success
    assert_equal false, response.parsed_body["replayed"]
    assert_not_equal first_signed_id, response.parsed_body["signed_id"]
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

  def authorization_headers(idempotency_key = nil)
    headers = { "Authorization" => "Bearer #{@token}" }
    headers["Idempotency-Key"] = idempotency_key if idempotency_key.present?
    headers
  end

  def with_forgery_protection
    original_base = ActionController::Base.allow_forgery_protection
    original_direct_uploads = ActiveStorage::DirectUploadsController.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    ActiveStorage::DirectUploadsController.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original_base
    ActiveStorage::DirectUploadsController.allow_forgery_protection = original_direct_uploads
  end
end
