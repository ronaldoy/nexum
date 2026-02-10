require "test_helper"

class PhysicianCnpjSplitPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
  end

  test "accepts valid shared cnpj policy for legal entity party" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      legal_entity = create_legal_entity_party("policy-valid")

      policy = PhysicianCnpjSplitPolicy.new(
        tenant: @tenant,
        legal_entity_party: legal_entity,
        scope: "SHARED_CNPJ",
        cnpj_share_rate: "0.30000000",
        physician_share_rate: "0.70000000",
        status: "ACTIVE",
        effective_from: Time.current
      )

      assert policy.valid?
    end
  end

  test "rejects policy when share rates do not add up to one" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      legal_entity = create_legal_entity_party("policy-invalid-rates")

      policy = PhysicianCnpjSplitPolicy.new(
        tenant: @tenant,
        legal_entity_party: legal_entity,
        scope: "SHARED_CNPJ",
        cnpj_share_rate: "0.35000000",
        physician_share_rate: "0.70000000",
        status: "ACTIVE",
        effective_from: Time.current
      )

      assert_not policy.valid?
      assert_includes policy.errors[:base], "cnpj_share_rate + physician_share_rate must equal 1.00000000"
    end
  end

  test "rejects non pj legal entity party" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      supplier_party = Party.create!(
        tenant: @tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor nao PJ legal entity",
        document_number: valid_cnpj_from_seed("policy-supplier")
      )

      policy = PhysicianCnpjSplitPolicy.new(
        tenant: @tenant,
        legal_entity_party: supplier_party,
        scope: "SHARED_CNPJ",
        cnpj_share_rate: "0.30000000",
        physician_share_rate: "0.70000000",
        status: "ACTIVE",
        effective_from: Time.current
      )

      assert_not policy.valid?
      assert_includes policy.errors[:legal_entity_party], "must be a LEGAL_ENTITY_PJ party"
    end
  end

  private

  def create_legal_entity_party(suffix)
    Party.create!(
      tenant: @tenant,
      kind: "LEGAL_ENTITY_PJ",
      legal_name: "Clinica #{suffix}",
      document_number: valid_cnpj_from_seed("legal-entity-#{suffix}")
    )
  end
end
