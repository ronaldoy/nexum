require "test_helper"

module Admin
  class PartnerApplicationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @secondary_tenant = tenants(:secondary)
      @ops_user = users(:one)
      @non_privileged_user = users(:two)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
      end

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @secondary_tenant.update!(active: true)
      end
    end

    test "ops_admin with passkey can view partner application management page" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_partner_applications_path(tenant_id: @secondary_tenant.id)

      assert_response :success
      assert_includes response.body, "Aplicações parceiras OAuth client credentials"
      assert_includes response.body, @secondary_tenant.slug
      assert_includes response.body, "Escopos suportados"
    end

    test "requires passkey step-up to access partner application management" do
      sign_in_as(@ops_user, admin_webauthn_verified: false)

      get admin_partner_applications_path

      assert_redirected_to new_admin_passkey_verification_path(return_to: admin_partner_applications_path)
    end

    test "non privileged user cannot access partner application management" do
      sign_in_as(@non_privileged_user, admin_webauthn_verified: true)

      get admin_partner_applications_path

      assert_redirected_to root_path
      follow_redirect!
      assert_includes response.body, "Acesso restrito ao perfil de operação."
    end

    test "creates partner application and shows client secret once" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      post admin_partner_applications_path, params: {
        partner_application: {
          tenant_id: @secondary_tenant.id,
          name: "Frontend Parceiro",
          scopes_input: "physicians:write receivables:write",
          token_ttl_minutes: 15,
          allowed_origins_input: "https://frontend.parceiro.com.br"
        }
      }

      assert_redirected_to admin_partner_applications_path(tenant_id: @secondary_tenant.id)
      follow_redirect!
      assert_response :success
      assert_includes response.body, "Credencial gerada"
      assert_includes response.body, "client_secret"

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        application = PartnerApplication.find_by!(tenant_id: @secondary_tenant.id, name: "Frontend Parceiro")
        assert_equal %w[physicians:write receivables:write], application.scopes
        assert_equal [ "https://frontend.parceiro.com.br" ], application.allowed_origins
      end
    end

    test "rejects unsupported scopes" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      post admin_partner_applications_path, params: {
        partner_application: {
          tenant_id: @secondary_tenant.id,
          name: "Escopo Invalido",
          scopes_input: "ops:write",
          token_ttl_minutes: 15
        }
      }

      assert_response :unprocessable_entity
      assert_includes response.body, "Escopos inválidos"
    end

    test "rotates secret and revokes active issued tokens" do
      application_id = nil
      old_digest = nil
      issued_token_id = nil

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        application, _client_secret = PartnerApplication.issue!(
          tenant: @secondary_tenant,
          created_by_user: @ops_user,
          name: "Rotate Me",
          scopes: %w[receivables:read]
        )
        issued = application.issue_access_token!
        application_id = application.id
        old_digest = application.client_secret_digest
        issued_token_id = issued.fetch(:token).id
      end

      sign_in_as(@ops_user, admin_webauthn_verified: true)

      post rotate_secret_admin_partner_application_path(application_id, tenant_id: @secondary_tenant.id)

      assert_redirected_to admin_partner_applications_path(tenant_id: @secondary_tenant.id)

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        application = PartnerApplication.find(application_id)
        token = ApiAccessToken.find(issued_token_id)

        assert_not_equal old_digest, application.client_secret_digest
        assert application.rotated_at.present?
        assert token.revoked_at.present?
      end
    end

    test "deactivates application and revokes active issued tokens" do
      application_id = nil
      issued_token_id = nil

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        application, _client_secret = PartnerApplication.issue!(
          tenant: @secondary_tenant,
          created_by_user: @ops_user,
          name: "Deactivate Me",
          scopes: %w[receivables:read]
        )
        issued = application.issue_access_token!
        application_id = application.id
        issued_token_id = issued.fetch(:token).id
      end

      sign_in_as(@ops_user, admin_webauthn_verified: true)

      patch deactivate_admin_partner_application_path(application_id, tenant_id: @secondary_tenant.id)

      assert_redirected_to admin_partner_applications_path(tenant_id: @secondary_tenant.id)

      with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        application = PartnerApplication.find(application_id)
        token = ApiAccessToken.find(issued_token_id)

        assert_equal false, application.active
        assert token.revoked_at.present?
      end
    end
  end
end
