module DatabaseContextTestHelper
  def with_tenant_db_context(tenant_id:, actor_id: nil, role: nil, request_id: nil)
    DatabaseRequestContext.with(
      tenant_id: tenant_id,
      actor_id: actor_id,
      role: role,
      request_id: request_id,
      local: false
    ) { yield }
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include DatabaseContextTestHelper
end
