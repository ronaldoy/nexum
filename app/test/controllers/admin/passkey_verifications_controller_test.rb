require "test_helper"

module Admin
  class PasskeyVerificationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @ops_user = users(:one)
      @non_privileged_user = users(:two)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
      end
    end

    test "ops_admin can open passkey verification page" do
      sign_in_as(@ops_user)

      get new_admin_passkey_verification_path

      assert_response :success
      assert_includes response.body, "Validar acesso ao painel administrativo"
    end

    test "non privileged user cannot open passkey verification page" do
      sign_in_as(@non_privileged_user)

      get new_admin_passkey_verification_path

      assert_redirected_to root_path
      follow_redirect!
      assert_includes response.body, "Acesso restrito ao perfil de operação."
    end

    test "registration_options issues a challenge for ops_admin" do
      sign_in_as(@ops_user)

      post registration_options_admin_passkey_verification_path, as: :json

      assert_response :success
      assert response.parsed_body["challenge"].present?
      @ops_user.reload
      assert @ops_user.webauthn_id.present?
    end

    test "authentication_options requires existing credential" do
      sign_in_as(@ops_user)

      post authentication_options_admin_passkey_verification_path, as: :json

      assert_response :unprocessable_entity
      assert_equal "passkey_not_registered", response.parsed_body.dig("error", "code")
    end

    test "authentication_options issues challenge when credential exists" do
      sign_in_as(@ops_user)
      create_webauthn_credential!

      post authentication_options_admin_passkey_verification_path, as: :json

      assert_response :success
      assert response.parsed_body["challenge"].present?
    end

    private

    def create_webauthn_credential!
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: @ops_user.role) do
        @ops_user.ensure_webauthn_id!
        WebauthnCredential.create!(
          tenant: @tenant,
          user: @ops_user,
          webauthn_id: "credential-#{SecureRandom.hex(8)}",
          public_key: "test-public-key",
          sign_count: 0,
          nickname: "Test key"
        )
      end
    end
  end
end
