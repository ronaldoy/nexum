require "test_helper"

class FdicOperationTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @actor = users(:one)
  end

  test "requires exactly one source reference" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @actor.id, role: "worker") do
      operation = FdicOperation.new(
        tenant: @tenant,
        provider: "MOCK",
        operation_type: "FUNDING_REQUEST",
        status: "PENDING",
        amount: "10.00",
        currency: "BRL",
        idempotency_key: "fdic-op-invalid-source",
        requested_at: Time.current
      )

      assert_not operation.valid?
      assert_includes operation.errors.full_messages.join(" "), "must reference either anticipation_request or receivable_payment_settlement"
    end
  end
end
