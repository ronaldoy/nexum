require "test_helper"

class ReceivableTest < ActiveSupport::TestCase
  test "normalizes brl currency input" do
    receivable = nil

    with_default_tenant_context do |tenant|
      receivable = build_receivable(tenant:, currency: "brl")
    end

    assert receivable.valid?
    assert_equal "BRL", receivable.currency
  end

  test "rejects non brl currency" do
    receivable = nil

    with_default_tenant_context do |tenant|
      receivable = build_receivable(tenant:, currency: "USD")
    end

    assert_not receivable.valid?
    assert_includes receivable.errors[:currency], "is not included in the list"
  end

  private

  def with_default_tenant_context
    tenant = tenants(:default)
    user = users(:one)

    with_tenant_db_context(tenant_id: tenant.id, actor_id: user.id, role: user.role) do
      yield tenant
    end
  end

  def build_receivable(tenant:, currency:)
    suffix = SecureRandom.hex(6)

    debtor_party = Party.create!(
      tenant: tenant,
      kind: "HOSPITAL",
      legal_name: "Hospital #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-hospital")
    )
    creditor_party = Party.create!(
      tenant: tenant,
      kind: "SUPPLIER",
      legal_name: "Fornecedor #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-supplier-creditor")
    )
    beneficiary_party = Party.create!(
      tenant: tenant,
      kind: "SUPPLIER",
      legal_name: "Beneficiario #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-supplier-beneficiary")
    )
    receivable_kind = ReceivableKind.create!(
      tenant: tenant,
      code: "supplier_invoice_#{suffix}",
      name: "Supplier Invoice #{suffix}",
      source_family: "SUPPLIER"
    )

    Receivable.new(
      tenant: tenant,
      receivable_kind: receivable_kind,
      debtor_party: debtor_party,
      creditor_party: creditor_party,
      beneficiary_party: beneficiary_party,
      external_reference: "external-#{suffix}",
      gross_amount: "100.00",
      currency: currency,
      performed_at: Time.current,
      due_at: 3.days.from_now,
      cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
    )
  end
end
