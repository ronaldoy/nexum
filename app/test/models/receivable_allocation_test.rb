require "test_helper"

class ReceivableAllocationTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
  end

  test "applies default 30/70 split for shared cnpj allocation" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      bundle = create_shared_cnpj_bundle("default-split")

      allocation = ReceivableAllocation.create!(
        tenant: @tenant,
        receivable: bundle[:receivable],
        sequence: 1,
        allocated_party: bundle[:legal_entity],
        physician_party: bundle[:physician_one],
        gross_amount: "100.00",
        status: "OPEN"
      )

      split = allocation.metadata.fetch("cnpj_split")
      assert_equal BigDecimal("30"), allocation.tax_reserve_amount.to_d
      assert_equal BigDecimal("70"), BigDecimal(split.fetch("physician_share_amount"))
      assert_equal "default", split.fetch("source")
      assert_equal "SHARED_CNPJ", split.fetch("scope")
    end
  end

  test "applies active split policy for shared cnpj allocation" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      bundle = create_shared_cnpj_bundle("policy-split")

      policy = PhysicianCnpjSplitPolicy.create!(
        tenant: @tenant,
        legal_entity_party: bundle[:legal_entity],
        scope: "SHARED_CNPJ",
        cnpj_share_rate: "0.40000000",
        physician_share_rate: "0.60000000",
        status: "ACTIVE",
        effective_from: Time.current - 1.minute
      )

      allocation = ReceivableAllocation.create!(
        tenant: @tenant,
        receivable: bundle[:receivable],
        sequence: 1,
        allocated_party: bundle[:legal_entity],
        physician_party: bundle[:physician_one],
        gross_amount: "100.00",
        status: "OPEN"
      )

      split = allocation.metadata.fetch("cnpj_split")
      assert_equal BigDecimal("40"), allocation.tax_reserve_amount.to_d
      assert_equal BigDecimal("60"), BigDecimal(split.fetch("physician_share_amount"))
      assert_equal "policy", split.fetch("source")
      assert_equal policy.id, split.fetch("policy_id")
    end
  end

  private

  def create_shared_cnpj_bundle(suffix)
    hospital = Party.create!(
      tenant: @tenant,
      kind: "HOSPITAL",
      legal_name: "Hospital #{suffix}",
      document_number: valid_cnpj_from_seed("hospital-#{suffix}")
    )
    legal_entity = Party.create!(
      tenant: @tenant,
      kind: "LEGAL_ENTITY_PJ",
      legal_name: "Clinica #{suffix}",
      document_number: valid_cnpj_from_seed("legal-entity-#{suffix}")
    )
    physician_one = Party.create!(
      tenant: @tenant,
      kind: "PHYSICIAN_PF",
      legal_name: "Medico PF 1 #{suffix}",
      document_number: valid_cpf_from_seed("physician-1-#{suffix}")
    )
    physician_two = Party.create!(
      tenant: @tenant,
      kind: "PHYSICIAN_PF",
      legal_name: "Medico PF 2 #{suffix}",
      document_number: valid_cpf_from_seed("physician-2-#{suffix}")
    )

    PhysicianLegalEntityMembership.create!(
      tenant: @tenant,
      physician_party: physician_one,
      legal_entity_party: legal_entity,
      membership_role: "ADMIN",
      status: "ACTIVE"
    )
    PhysicianLegalEntityMembership.create!(
      tenant: @tenant,
      physician_party: physician_two,
      legal_entity_party: legal_entity,
      membership_role: "MEMBER",
      status: "ACTIVE"
    )

    kind = ReceivableKind.create!(
      tenant: @tenant,
      code: "physician_shift_#{suffix}",
      name: "Physician Shift #{suffix}",
      source_family: "PHYSICIAN"
    )

    receivable = Receivable.create!(
      tenant: @tenant,
      receivable_kind: kind,
      debtor_party: hospital,
      creditor_party: legal_entity,
      beneficiary_party: legal_entity,
      external_reference: "receivable-#{suffix}",
      gross_amount: "100.00",
      currency: "BRL",
      performed_at: Time.current,
      due_at: 3.days.from_now,
      cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
    )

    {
      hospital: hospital,
      legal_entity: legal_entity,
      physician_one: physician_one,
      physician_two: physician_two,
      receivable: receivable
    }
  end
end
