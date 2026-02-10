require "test_helper"

class PhysicianTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @user = users(:one)
  end

  test "normalizes crm_number and crm_state" do
    with_default_tenant_context do
      physician = Physician.new(
        tenant: @tenant,
        party: create_physician_party!("crm-normalize"),
        full_name: "Dra. Estado Normalizado",
        crm_number: "12.345",
        crm_state: "sp"
      )

      assert physician.valid?
      assert_equal "12345", physician.crm_number
      assert_equal "SP", physician.crm_state
    end
  end

  test "rejects crm_state outside brazilian uf list" do
    with_default_tenant_context do
      physician = Physician.new(
        tenant: @tenant,
        party: create_physician_party!("crm-invalid-state"),
        full_name: "Dr. UF Invalida",
        crm_number: "12345",
        crm_state: "XX"
      )

      assert_not physician.valid?
      assert_includes physician.errors[:crm_state], "is not included in the list"
    end
  end

  test "requires crm_number and crm_state together" do
    with_default_tenant_context do
      physician = Physician.new(
        tenant: @tenant,
        party: create_physician_party!("crm-pair"),
        full_name: "Dr. Par Incompleto",
        crm_number: "12345",
        crm_state: nil
      )

      assert_not physician.valid?
      assert_includes physician.errors[:base], "crm_number and crm_state must be provided together"
    end
  end

  test "enforces crm uniqueness per tenant and state" do
    with_default_tenant_context do
      Physician.create!(
        tenant: @tenant,
        party: create_physician_party!("crm-unique-a"),
        full_name: "Dr. Unico A",
        crm_number: "12345",
        crm_state: "SP"
      )

      duplicate = Physician.new(
        tenant: @tenant,
        party: create_physician_party!("crm-unique-b"),
        full_name: "Dr. Unico B",
        crm_number: "12345",
        crm_state: "SP"
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:crm_number], "has already been taken"
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
      document_number: valid_cpf_from_seed("physician-#{suffix}")
    )
  end
end
