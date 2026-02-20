require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup { @user = User.take }

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path, params: { tenant_slug: @user.tenant.slug, email_address: @user.email_address, password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id]
    assert cookies[:session_tenant_id]
    assert cookies[:session_user_uuid_id]

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      assert_equal 1, ActionIpLog.where(
        tenant_id: @user.tenant_id,
        action_type: "SESSION_AUTHENTICATED",
        success: true
      ).count
    end
  end

  test "create sets hardened session cookie attributes" do
    post session_path, params: { tenant_slug: @user.tenant.slug, email_address: @user.email_address, password: "password" }

    set_cookie_header = response.headers["Set-Cookie"].to_s.downcase

    assert_includes set_cookie_header, "httponly"
    assert_includes set_cookie_header, "samesite=strict"
  end

  test "create with invalid credentials" do
    post session_path, params: { tenant_slug: @user.tenant.slug, email_address: @user.email_address, password: "wrong" }

    assert_response :redirect
    assert_nil cookies[:session_id]

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      assert_equal 1, ActionIpLog.where(
        tenant_id: @user.tenant_id,
        action_type: "SESSION_AUTHENTICATION_FAILED",
        success: false
      ).count
    end
  end

  test "create with invalid tenant slug" do
    post session_path, params: { tenant_slug: "nonexistent", email_address: @user.email_address, password: "password" }

    assert_response :redirect
    assert_nil cookies[:session_id]
  end

  test "create with blank tenant slug" do
    post session_path, params: { tenant_slug: "", email_address: @user.email_address, password: "password" }

    assert_response :redirect
    assert_nil cookies[:session_id]
  end

  test "privileged users require MFA code" do
    ops_user = nil
    mfa_code = nil
    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      ops_user = User.create!(
        tenant: @user.tenant,
        party: @user.party,
        role: "ops_admin",
        email_address: "ops-login@example.com",
        password: "password",
        password_confirmation: "password",
        mfa_enabled: true,
        mfa_secret: ROTP::Base32.random
      )
      mfa_code = ROTP::TOTP.new(ops_user.mfa_secret).now
    end

    post session_path, params: { tenant_slug: @user.tenant.slug, email_address: ops_user.email_address, password: "password" }

    assert_response :redirect
    assert_nil cookies[:session_id]

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      assert_equal 1, ActionIpLog.where(
        tenant_id: @user.tenant_id,
        action_type: "SESSION_MFA_FAILED",
        success: false
      ).count
    end

    post session_path, params: { tenant_slug: @user.tenant.slug, email_address: ops_user.email_address, password: "password", otp_code: mfa_code }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "destroy" do
    sign_in_as(@user)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      assert_equal 1, ActionIpLog.where(
        tenant_id: @user.tenant_id,
        action_type: "SESSION_TERMINATED",
        success: true
      ).count
    end
  end

  test "create accepts same-origin request when forgery protection is enabled" do
    with_forgery_protection do
      post session_path,
           params: { tenant_slug: @user.tenant.slug, email_address: @user.email_address, password: "password" },
           headers: { "Sec-Fetch-Site" => "same-origin" }
    end

    assert_redirected_to root_path
    assert cookies[:session_id]
    assert cookies[:session_user_uuid_id]
  end

  test "create rejects cross-site request when forgery protection is enabled" do
    with_forgery_protection do
      post session_path,
           params: { tenant_slug: @user.tenant.slug, email_address: @user.email_address, password: "password" },
           headers: { "Sec-Fetch-Site" => "cross-site" }
    end

    assert_response :unprocessable_entity
    assert_nil cookies[:session_id]
  end

  test "expired session is rejected and user is redirected to login" do
    sign_in_as(@user)

    travel Session.ttl + 1.second do
      get root_path
    end

    assert_redirected_to new_session_path
    assert_equal "", cookies[:session_id]
  end

  test "rejects resumed session when persisted user uuid drifts from cookie" do
    sign_in_as(@user)

    drift_user = nil
    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      drift_party = Party.create!(
        tenant: @user.tenant,
        kind: "SUPPLIER",
        legal_name: "Drift User Party",
        document_number: valid_cnpj_from_seed("session-drift-party")
      )
      drift_user = User.create!(
        tenant: @user.tenant,
        party: drift_party,
        role: "supplier_user",
        email_address: "drift-user@example.com",
        password: "password",
        password_confirmation: "password"
      )

      session_record = Session.find(Current.session.id)
      session_record.update_columns(user_uuid_id: drift_user.uuid_id)
    end

    get root_path

    assert_redirected_to new_session_path
    assert_equal "", cookies[:session_id]
  end

  private

  def with_forgery_protection
    original = ApplicationController.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    yield
  ensure
    ApplicationController.allow_forgery_protection = original
  end
end
