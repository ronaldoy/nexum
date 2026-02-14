require "test_helper"

class RoleTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
  end

  test "normalizes code and infers name when missing" do
    role = Role.create!(tenant: @tenant, code: " HOSPITAL_ADMIN ")

    assert_equal "hospital_admin", role.code
    assert_equal "Hospital admin", role.name
  end

  test "rejects unsupported role code" do
    role = Role.new(tenant: @tenant, code: "finance_admin", name: "Finance Admin")

    assert_not role.valid?
    assert_includes role.errors[:code], "is not included in the list"
  end

  test "enforces uniqueness per tenant" do
    role = Role.new(tenant: @tenant, code: "supplier_user", name: "Fornecedor")

    assert_not role.valid?
    assert_includes role.errors[:code], "has already been taken"
  end
end
