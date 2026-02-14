module RequestContext
  extend ActiveSupport::Concern

  class ContextError < StandardError; end

  included do
    around_action :with_request_connection
    before_action :populate_request_context
    before_action :apply_database_request_context
  end

  private

  def with_request_connection
    ActiveRecord::Base.connection_pool.with_connection do
      ActiveRecord::Base.transaction(requires_new: true) do
        yield
      end
    end
  ensure
    Current.reset
  end

  def populate_request_context
    Current.request_id = request.request_id
    Current.tenant_id = resolved_tenant_id
    Current.actor_id = resolved_actor_id
  end

  def resolved_tenant_id
    Current.tenant_id || Current.user&.tenant_id
  end

  def resolved_actor_id
    Current.user&.party_id || Current.user&.id
  end

  def resolved_role
    Current.user&.role
  end

  def apply_database_request_context
    set_database_context!("app.tenant_id", Current.tenant_id)
    set_database_context!("app.actor_id", Current.actor_id)
    Current.role = resolved_role
    set_database_context!("app.role", Current.role)
  end

  def set_database_context!(key, value)
    self.class.set_database_context!(key, value)
  end

  class_methods do
    def set_database_context!(key, value)
      ActiveRecord::Base.connection.raw_connection.exec_params(
        "SELECT set_config($1, $2, true)",
        [key.to_s, value.to_s]
      )
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid => error
      raise ContextError, "failed to apply request context #{key}: #{error.message}"
    end
  end

  def bootstrap_database_tenant_context!(tenant_id)
    return if tenant_id.blank?

    self.class.set_database_context!("app.tenant_id", tenant_id)
  end

  def clear_bootstrap_database_tenant_context!
    self.class.set_database_context!("app.tenant_id", "")
  end

  def resolve_tenant_id_from_slug(slug)
    normalized_slug = slug.to_s.strip.downcase
    return nil if normalized_slug.blank?

    set_database_context!("app.allow_tenant_slug_lookup", "true")
    set_database_context!("app.requested_tenant_slug", normalized_slug)

    ActiveRecord::Base.connection.select_value(
      "SELECT app_resolve_tenant_id_by_slug(#{ActiveRecord::Base.connection.quote(normalized_slug)})"
    )
  ensure
    set_database_context!("app.requested_tenant_slug", "")
    set_database_context!("app.allow_tenant_slug_lookup", "false")
  end
end
