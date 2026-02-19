require "test_helper"

class HospitalOwnershipTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @other_tenant = tenants(:secondary)
  end

  test "validates legal entity organization owning a hospital" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      organization = Party.create!(
        tenant: @tenant,
        kind: "LEGAL_ENTITY_PJ",
        legal_name: "Grupo Hospitalar Principal",
        document_number: valid_cnpj_from_seed("hospital-ownership-org")
      )
      hospital = Party.create!(
        tenant: @tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital Principal",
        document_number: valid_cnpj_from_seed("hospital-ownership-hospital")
      )

      ownership = HospitalOwnership.new(
        tenant: @tenant,
        organization_party: organization,
        hospital_party: hospital
      )

      assert ownership.valid?
    end
  end

  test "rejects ownership records when parties are not in the same tenant" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      organization = Party.create!(
        tenant: @tenant,
        kind: "LEGAL_ENTITY_PJ",
        legal_name: "Grupo Hospitalar Tenant A",
        document_number: valid_cnpj_from_seed("hospital-ownership-tenant-a-org")
      )
      cross_tenant_hospital = nil

      with_tenant_db_context(tenant_id: @other_tenant.id) do
        cross_tenant_hospital = Party.create!(
          tenant: @other_tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital Tenant B",
          document_number: valid_cnpj_from_seed("hospital-ownership-tenant-b-hospital")
        )
      end

      ownership = HospitalOwnership.new(
        tenant: @tenant,
        organization_party: organization,
        hospital_party: cross_tenant_hospital
      )

      assert_not ownership.valid?
      assert_includes ownership.errors[:hospital_party], "must belong to the same tenant"
    end
  end

  test "enables and forces RLS with tenant policy on hospital ownerships" do
    connection = ActiveRecord::Base.connection

    rls_row = connection.select_one(<<~SQL)
      SELECT relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE oid = 'hospital_ownerships'::regclass
    SQL

    assert_equal true, rls_row["relrowsecurity"]
    assert_equal true, rls_row["relforcerowsecurity"]

    policy = connection.select_one(<<~SQL)
      SELECT policyname, qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'hospital_ownerships'
        AND policyname = 'hospital_ownerships_tenant_policy'
    SQL

    assert policy.present?
    assert_includes policy["qual"], "tenant_id"
    assert_includes policy["with_check"], "tenant_id"
  end
end
