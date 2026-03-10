require "test_helper"

module Admin
  class CounterpartiesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @ops_user = users(:one)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
        @hospital = Party.create!(
          tenant: @tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital Cockpit",
          document_number: valid_cnpj_from_seed("counterparty-hospital")
        )
      end
    end

    test "ops admin creates physician with cpf and profile" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      post admin_counterparties_path, params: {
        counterparty: {
          kind: "PHYSICIAN_PF",
          legal_name: "Dra. Marina Teste",
          document_number: valid_cpf_from_seed("counterparty-physician"),
          email: "marina@example.com",
          phone: "11999999999",
          crm_number: "12345",
          crm_state: "SP"
        }
      }

      assert_redirected_to admin_counterparties_path

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        party = Party.order(created_at: :desc).first
        physician = Physician.order(created_at: :desc).first

        assert_equal "PHYSICIAN_PF", party.kind
        assert_equal "CPF", party.document_type
        assert_equal party.id, physician.party_id
      end
    end

    test "ops admin creates legal entity with cnpj and links hospital" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      post admin_counterparties_path, params: {
        counterparty: {
          kind: "LEGAL_ENTITY_PJ",
          legal_name: "Clinica Auditada LTDA",
          document_number: valid_cnpj_from_seed("counterparty-legal"),
          display_name: "Clinica Auditada"
        }
      }

      assert_redirected_to admin_counterparties_path

      created_party_id = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        party = Party.order(created_at: :desc).first
        assert_equal "LEGAL_ENTITY_PJ", party.kind
        assert_equal "CNPJ", party.document_type
        party.id
      end

      post link_hospital_admin_counterparties_path, params: {
        hospital_ownership: {
          organization_party_id: created_party_id,
          hospital_party_id: @hospital.id
        }
      }

      assert_redirected_to admin_counterparties_path

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        assert HospitalOwnership.where(tenant_id: @tenant.id, organization_party_id: created_party_id, hospital_party_id: @hospital.id).exists?
      end
    end

    test "counterparty creation rejects cpf cnpj mismatches for the selected kind" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      baseline_party_count = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        Party.count
      end

      post admin_counterparties_path, params: {
        counterparty: {
          kind: "PHYSICIAN_PF",
          legal_name: "Dr. Documento Incorreto",
          document_number: valid_cnpj_from_seed("counterparty-invalid-physician")
        }
      }

      assert_response :unprocessable_entity
      assert_includes response.body, "must be a valid CPF"
      assert_includes response.body, "Vincular hospital à organização"

      post admin_counterparties_path, params: {
        counterparty: {
          kind: "LEGAL_ENTITY_PJ",
          legal_name: "Clinica Documento Incorreto",
          document_number: valid_cpf_from_seed("counterparty-invalid-entity")
        }
      }

      assert_response :unprocessable_entity
      assert_includes response.body, "must be a valid CNPJ"
      assert_includes response.body, "Vincular hospital à organização"

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        assert_equal baseline_party_count, Party.count
      end
    end
  end
end
