require "test_helper"

class SecurityThrottlingTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @target_email = "target-account@example.com"
    @original_rack_attack_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.cache.store.clear
  end

  teardown do
    Rack::Attack.cache.store = @original_rack_attack_store
  end

  test "throttles login attempts per account across distinct ips" do
    8.times do |index|
      post session_path,
        params: {
          tenant_slug: @user.tenant.slug,
          email_address: @target_email,
          password: "wrong-password"
        },
        env: { "REMOTE_ADDR" => "198.51.100.#{index + 10}" }

      assert_response :redirect
    end

    post session_path,
      params: {
        tenant_slug: @user.tenant.slug,
        email_address: @target_email,
        password: "wrong-password"
      },
      env: { "REMOTE_ADDR" => "203.0.113.20" }

    assert_response :too_many_requests
  end

  test "throttles password reset attempts per account across distinct ips" do
    6.times do |index|
      post passwords_path,
        params: {
          tenant_slug: @user.tenant.slug,
          email_address: @target_email
        },
        env: { "REMOTE_ADDR" => "198.51.100.#{index + 40}" }

      assert_response :redirect
    end

    post passwords_path,
      params: {
        tenant_slug: @user.tenant.slug,
        email_address: @target_email
      },
      env: { "REMOTE_ADDR" => "203.0.113.40" }

    assert_response :too_many_requests
  end
end
