module TenantDatabaseContext
  extend ActiveSupport::Concern

  private

  def with_tenant_database_context(tenant_id:, actor_id: nil, role: "worker")
    DatabaseRequestContext.with(tenant_id: tenant_id, actor_id: actor_id, role: role) { yield }
  end
end
