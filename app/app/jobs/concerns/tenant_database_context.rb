module TenantDatabaseContext
  extend ActiveSupport::Concern

  private

  def with_tenant_database_context(tenant_id:, actor_id: nil, role: "worker")
    ActiveRecord::Base.connection_pool.with_connection do
      ActiveRecord::Base.transaction(requires_new: true) do
        set_database_context!("app.tenant_id", tenant_id)
        set_database_context!("app.actor_id", actor_id)
        set_database_context!("app.role", role)
        yield
      end
    end
  end

  def set_database_context!(key, value)
    ActiveRecord::Base.connection.raw_connection.exec_params(
      "SELECT set_config($1, $2, true)",
      [ key.to_s, value.to_s ]
    )
  end
end
