require "test_helper"

class UserRoleTest < ActiveSupport::TestCase
  setup do
    @default_tenant = tenants(:default)
    @default_user = users(:one)
    @secondary_user = users(:two)
  end

  test "rejects assigning multiple roles to same user within tenant" do
    role = Role.create!(tenant: @default_tenant, code: "ops_admin", name: "Ops admin")
    user_role = UserRole.new(tenant: @default_tenant, user: @default_user, role: role)

    assert_not user_role.valid?
    assert_includes user_role.errors[:user_uuid_id], "has already been taken"
  end

  test "requires user and role to match tenant" do
    user_role = UserRole.new(
      tenant: @default_tenant,
      user: @secondary_user,
      role: roles(:default_supplier)
    )

    assert_not user_role.valid?
    assert_includes user_role.errors[:user], "must belong to the same tenant"
  end

  test "rejects role from another tenant" do
    user_role = UserRole.new(
      tenant: @default_tenant,
      user: @default_user,
      role: roles(:secondary_supplier)
    )

    assert_not user_role.valid?
    assert_includes user_role.errors[:role], "must belong to the same tenant"
  end
end
