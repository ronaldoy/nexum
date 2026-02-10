module RequestContext
  extend ActiveSupport::Concern

  included do
    around_action :with_request_connection
    before_action :populate_request_context
    before_action :apply_database_request_context
    after_action :clear_database_request_context
  end

  private

  def with_request_connection
    ActiveRecord::Base.connection_pool.with_connection do
      yield
    end
  end

  def populate_request_context
    Current.request_id = request.request_id
    Current.tenant_id = resolved_tenant_id
    Current.actor_id = resolved_actor_id
    Current.role = resolved_role
  end

  def resolved_tenant_id
    Current.user&.tenant_id
  end

  def resolved_actor_id
    Current.user&.party_id || Current.user&.id
  end

  def resolved_role
    Current.user&.role
  end

  def apply_database_request_context
    set_database_context("app.tenant_id", Current.tenant_id)
    set_database_context("app.actor_id", Current.actor_id)
    set_database_context("app.role", Current.role)
  end

  def clear_database_request_context
    set_database_context("app.tenant_id", nil)
    set_database_context("app.actor_id", nil)
    set_database_context("app.role", nil)
  ensure
    Current.reset
  end

  def set_database_context(key, value)
    connection = ActiveRecord::Base.connection
    connection.execute(
      "SELECT set_config(#{connection.quote(key)}, #{connection.quote(value.to_s)}, false)"
    )
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
    nil
  end
end
