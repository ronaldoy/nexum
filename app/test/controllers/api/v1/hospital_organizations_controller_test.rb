require "test_helper"

module Api
  module V1
    class HospitalOrganizationsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @tenant = tenants(:default)
        @secondary_tenant = tenants(:secondary)
        @user = users(:one)

        @read_token = nil
        @tenant_bundle = nil
        @secondary_bundle = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          @user.update!(role: "ops_admin")
        end

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          _, @read_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Hospital Organizations API",
            scopes: %w[receivables:read]
          )
          @tenant_bundle = create_hospital_organization_bundle!(tenant: @tenant, suffix: "tenant-a")
        end

        with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @user.id, role: @user.role) do
          @secondary_bundle = create_hospital_organization_bundle!(tenant: @secondary_tenant, suffix: "tenant-b")
        end
      end

      test "lists hospital organizations scoped by tenant for privileged actors" do
        get api_v1_hospital_organizations_path, headers: authorization_headers(@read_token), as: :json

        assert_response :success
        assert_equal 1, response.parsed_body.dig("meta", "count")

        payload = response.parsed_body.dig("data", 0)
        assert_equal @tenant_bundle[:organization].id, payload.dig("organization", "id")
        assert_equal 2, payload.fetch("hospitals").size
        hospital_ids = payload.fetch("hospitals").map { |entry| entry.fetch("id") }
        assert_includes hospital_ids, @tenant_bundle[:hospital_a].id
        assert_includes hospital_ids, @tenant_bundle[:hospital_b].id
        refute_includes hospital_ids, @secondary_bundle[:hospital_a].id
      end

      test "non privileged organization actor sees only its linked hospitals" do
        token = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          organization_user = User.create!(
            tenant: @tenant,
            party: @tenant_bundle[:organization],
            email_address: "hospital-org-viewer@example.com",
            password: "password",
            password_confirmation: "password",
            role: "supplier_user"
          )
          _, token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: organization_user,
            name: "Org scoped view",
            scopes: %w[receivables:read]
          )
        end

        get api_v1_hospital_organizations_path, headers: authorization_headers(token), as: :json

        assert_response :success
        assert_equal 1, response.parsed_body.dig("meta", "count")
        payload = response.parsed_body.dig("data", 0)
        assert_equal @tenant_bundle[:organization].id, payload.dig("organization", "id")
        assert_equal 2, payload.fetch("hospitals").size
      end

      test "non privileged hospital actor sees owning organizations for its hospital" do
        token = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          hospital_user = User.create!(
            tenant: @tenant,
            party: @tenant_bundle[:hospital_a],
            email_address: "hospital-unit-viewer@example.com",
            password: "password",
            password_confirmation: "password",
            role: "supplier_user"
          )
          _, token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: hospital_user,
            name: "Hospital scoped view",
            scopes: %w[receivables:read]
          )
        end

        get api_v1_hospital_organizations_path, headers: authorization_headers(token), as: :json

        assert_response :success
        assert_equal 1, response.parsed_body.dig("meta", "count")
        payload = response.parsed_body.dig("data", 0)
        assert_equal @tenant_bundle[:organization].id, payload.dig("organization", "id")
        hospital_ids = payload.fetch("hospitals").map { |entry| entry.fetch("id") }
        assert_includes hospital_ids, @tenant_bundle[:hospital_a].id
      end

      private

      def authorization_headers(raw_token)
        { "Authorization" => "Bearer #{raw_token}" }
      end

      def create_hospital_organization_bundle!(tenant:, suffix:)
        organization = Party.create!(
          tenant: tenant,
          kind: "LEGAL_ENTITY_PJ",
          legal_name: "Grupo Hospitalar #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-hospital-org")
        )
        hospital_a = Party.create!(
          tenant: tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital #{suffix} A",
          document_number: valid_cnpj_from_seed("#{suffix}-hospital-a")
        )
        hospital_b = Party.create!(
          tenant: tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital #{suffix} B",
          document_number: valid_cnpj_from_seed("#{suffix}-hospital-b")
        )

        HospitalOwnership.create!(
          tenant: tenant,
          organization_party: organization,
          hospital_party: hospital_a
        )
        HospitalOwnership.create!(
          tenant: tenant,
          organization_party: organization,
          hospital_party: hospital_b
        )

        {
          organization: organization,
          hospital_a: hospital_a,
          hospital_b: hospital_b
        }
      end
    end
  end
end
