require "test_helper"

class KycDocumentTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @user = users(:one)
  end

  test "accepts valid key document for cpf" do
    with_default_tenant_context do
      party = create_physician_party!("key-cpf")
      profile = KycProfile.create!(
        tenant: @tenant,
        party: party,
        status: "DRAFT",
        risk_level: "UNKNOWN"
      )

      document = KycDocument.new(
        tenant: @tenant,
        kyc_profile: profile,
        party: party,
        document_type: "cpf",
        is_key_document: true,
        issuing_country: "br",
        status: "submitted",
        storage_key: "kyc/cpf-key.pdf",
        sha256: "abc123"
      )

      assert document.valid?
      assert_equal "CPF", document.document_type
      assert_equal "BR", document.issuing_country
      assert_equal "SUBMITTED", document.status
    end
  end

  test "rejects rg as key document" do
    with_default_tenant_context do
      party = create_physician_party!("rg-key")
      profile = KycProfile.create!(tenant: @tenant, party: party)

      document = KycDocument.new(
        tenant: @tenant,
        kyc_profile: profile,
        party: party,
        document_type: "RG",
        is_key_document: true,
        issuing_country: "BR",
        status: "SUBMITTED",
        storage_key: "kyc/rg.pdf",
        sha256: "abc123"
      )

      assert_not document.valid?
      assert_includes document.errors[:document_type], "can be key only for CPF or CNPJ"
      assert_includes document.errors[:is_key_document], "must be false for RG, CNH or PASSPORT"
    end
  end

  test "validates issuing_state against brazilian uf list" do
    with_default_tenant_context do
      party = create_physician_party!("issuing-state")
      profile = KycProfile.create!(tenant: @tenant, party: party)

      invalid_state_document = KycDocument.new(
        tenant: @tenant,
        kyc_profile: profile,
        party: party,
        document_type: "PROOF_OF_ADDRESS",
        issuing_country: "BR",
        issuing_state: "XX",
        status: "SUBMITTED",
        storage_key: "kyc/address.pdf",
        sha256: "abc123"
      )

      assert_not invalid_state_document.valid?
      assert_includes invalid_state_document.errors[:issuing_state], "is not included in the list"
    end
  end

  test "requires BR issuing_country when issuing_state is provided" do
    with_default_tenant_context do
      party = create_physician_party!("state-country")
      profile = KycProfile.create!(tenant: @tenant, party: party)

      document = KycDocument.new(
        tenant: @tenant,
        kyc_profile: profile,
        party: party,
        document_type: "PASSPORT",
        issuing_country: "US",
        issuing_state: "SP",
        status: "SUBMITTED",
        storage_key: "kyc/passport.pdf",
        sha256: "abc123"
      )

      assert_not document.valid?
      assert_includes document.errors[:issuing_state], "is only supported for issuing_country BR"
    end
  end

  test "requires document party to match profile party" do
    with_default_tenant_context do
      profile_party = create_physician_party!("profile-party")
      document_party = create_physician_party!("document-party")

      profile = KycProfile.create!(tenant: @tenant, party: profile_party)

      document = KycDocument.new(
        tenant: @tenant,
        kyc_profile: profile,
        party: document_party,
        document_type: "CPF",
        issuing_country: "BR",
        status: "SUBMITTED",
        storage_key: "kyc/cpf.pdf",
        sha256: "abc123"
      )

      assert_not document.valid?
      assert_includes document.errors[:party_id], "must match the KYC profile party"
    end
  end

  private

  def with_default_tenant_context(&block)
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role, &block)
  end

  def create_physician_party!(suffix)
    Party.create!(
      tenant: @tenant,
      kind: "PHYSICIAN_PF",
      legal_name: "Medico #{suffix}",
      document_number: valid_cpf_from_seed("kyc-#{suffix}")
    )
  end
end
