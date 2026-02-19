require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_password_path
    assert_response :success
  end

  test "create" do
    post passwords_path, params: { tenant_slug: @user.tenant.slug, email_address: @user.email_address }
    assert_enqueued_email_with PasswordsMailer, :reset, args: [ @user, { tenant_slug: @user.tenant.slug } ]
    assert_redirected_to new_session_path(tenant_slug: @user.tenant.slug)

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      log = ActionIpLog.where(
        tenant_id: @user.tenant_id,
        action_type: "PASSWORD_RESET_REQUESTED",
        success: true
      ).order(occurred_at: :desc).first
      assert log.present?
      assert_equal @user.id, log.metadata["user_id"]
    end

    follow_redirect!
    assert_notice "instruções para redefinição de senha"
  end

  test "create for an unknown user redirects but sends no mail" do
    post passwords_path, params: { tenant_slug: @user.tenant.slug, email_address: "missing-user@example.com" }
    assert_enqueued_emails 0
    assert_redirected_to new_session_path(tenant_slug: @user.tenant.slug)

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      log = ActionIpLog.where(
        tenant_id: @user.tenant_id,
        action_type: "PASSWORD_RESET_REQUESTED",
        success: true
      ).order(occurred_at: :desc).first
      assert log.present?
      assert_equal false, log.metadata["user_found"]
    end

    follow_redirect!
    assert_notice "instruções para redefinição de senha"
  end

  test "create with invalid tenant slug redirects back" do
    post passwords_path, params: { tenant_slug: "nonexistent", email_address: @user.email_address }
    assert_response :redirect
    assert_enqueued_emails 0
  end

  test "edit" do
    get edit_password_path(@user.password_reset_token, tenant_slug: @user.tenant.slug)
    assert_response :success
  end

  test "edit with invalid password reset token" do
    get edit_password_path("invalid token", tenant_slug: @user.tenant.slug)
    assert_redirected_to new_password_path(tenant_slug: @user.tenant.slug)

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      assert_equal 1, ActionIpLog.where(
        tenant_id: @user.tenant_id,
        action_type: "PASSWORD_RESET_TOKEN_INVALID",
        success: false
      ).count
    end

    follow_redirect!
    assert_notice "link de redefinição de senha é inválido"
  end

  test "edit without tenant slug redirects" do
    get edit_password_path(@user.password_reset_token)
    assert_redirected_to new_password_path
  end

  test "update" do
    assert_changes -> { @user.reload.password_digest } do
      put password_path(@user.password_reset_token), params: { tenant_slug: @user.tenant.slug, password: "new", password_confirmation: "new" }
      assert_redirected_to new_session_path(tenant_slug: @user.tenant.slug)
    end

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      log = ActionIpLog.where(
        tenant_id: @user.tenant_id,
        action_type: "PASSWORD_RESET_COMPLETED",
        success: true
      ).order(occurred_at: :desc).first
      assert log.present?
      assert_equal @user.id, log.metadata["user_id"]
    end

    follow_redirect!
    assert_notice "senha foi redefinida"
  end

  test "update with non matching passwords" do
    token = @user.password_reset_token
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token), params: { tenant_slug: @user.tenant.slug, password: "no", password_confirmation: "match" }
      assert_response :redirect
    end

    with_tenant_db_context(tenant_id: @user.tenant_id, actor_id: @user.id, role: @user.role) do
      log = ActionIpLog.where(
        tenant_id: @user.tenant_id,
        action_type: "PASSWORD_RESET_FAILED",
        success: false
      ).order(occurred_at: :desc).first
      assert log.present?
      assert_equal @user.id, log.metadata["user_id"]
    end

    follow_redirect!
    assert_notice "senhas não conferem"
  end

  private
    def assert_notice(text)
      assert_select "div", /#{text}/
    end
end
