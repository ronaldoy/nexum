module DatabaseContextTestHelper
  def with_tenant_db_context(tenant_id:, actor_id: nil, role: nil)
    apply_db_context("app.tenant_id", tenant_id)
    apply_db_context("app.actor_id", actor_id)
    apply_db_context("app.role", role)
    yield
  ensure
    apply_db_context("app.tenant_id", nil)
    apply_db_context("app.actor_id", nil)
    apply_db_context("app.role", nil)
  end

  private

  def apply_db_context(key, value)
    connection = ActiveRecord::Base.connection
    connection.execute(
      "SELECT set_config(#{connection.quote(key)}, #{connection.quote(value.to_s)}, false)"
    )
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include DatabaseContextTestHelper
end
