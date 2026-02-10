require "test_helper"

class PartyTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
  end

  test "accepts and normalizes valid cpf for physician pf" do
    cpf_digits = valid_cpf_from_seed("physician-pf")
    party = Party.new(
      tenant: @tenant,
      kind: "PHYSICIAN_PF",
      legal_name: "Dr. Pessoa Fisica",
      document_number: format_cpf(cpf_digits)
    )

    assert party.valid?
    assert_equal "CPF", party.document_type
    assert_equal cpf_digits, party.document_number
  end

  test "rejects invalid cpf for physician pf" do
    party = Party.new(
      tenant: @tenant,
      kind: "PHYSICIAN_PF",
      legal_name: "Dr. CPF Invalido",
      document_number: "123.456.789-00"
    )

    assert_not party.valid?
    assert_includes party.errors[:document_number], "must be a valid CPF"
  end

  test "accepts and normalizes valid cnpj for supplier" do
    cnpj_digits = valid_cnpj_from_seed("supplier-entity")
    party = Party.new(
      tenant: @tenant,
      kind: "SUPPLIER",
      legal_name: "Fornecedor PJ",
      document_number: format_cnpj(cnpj_digits)
    )

    assert party.valid?
    assert_equal "CNPJ", party.document_type
    assert_equal cnpj_digits, party.document_number
  end

  test "rejects invalid cnpj for supplier" do
    party = Party.new(
      tenant: @tenant,
      kind: "SUPPLIER",
      legal_name: "Fornecedor CNPJ Invalido",
      document_number: "12.345.678/0001-00"
    )

    assert_not party.valid?
    assert_includes party.errors[:document_number], "must be a valid CNPJ"
  end

  test "requires document number" do
    party = Party.new(
      tenant: @tenant,
      kind: "SUPPLIER",
      legal_name: "Fornecedor Sem Documento",
      document_number: nil
    )

    assert_not party.valid?
    assert_includes party.errors[:document_number], "can't be blank"
  end

  test "rejects mismatched document type and kind" do
    party = Party.new(
      tenant: @tenant,
      kind: "PHYSICIAN_PF",
      legal_name: "Dr. Tipo Invalido",
      document_type: "CNPJ",
      document_number: valid_cnpj_from_seed("invalid-type-physician")
    )

    assert_not party.valid?
    assert_includes party.errors[:document_type], "must be CPF for kind PHYSICIAN_PF"
  end
end
