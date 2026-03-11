module AdminTenantScopedContext
  extend ActiveSupport::Concern

  private

  def with_tenant_database_context(tenant_id:)
    DatabaseRequestContext.with(
      tenant_id: tenant_id,
      actor_id: tenant_scoped_database_actor_id(tenant_id),
      role: Current.role,
      request_id: Current.request_id
    ) { yield }
  end

  def tenant_scoped_audit_context(tenant_id:, metadata: {})
    {
      tenant_id: tenant_id,
      actor_party_id: tenant_scoped_audit_actor_party_id(tenant_id),
      ip_address: request.remote_ip,
      user_agent: request.user_agent,
      request_id: request.request_id,
      endpoint_path: request.fullpath,
      http_method: request.method,
      channel: "ADMIN",
      metadata: tenant_scoped_audit_metadata(tenant_id:, metadata:)
    }
  end

  def tenant_scoped_audit_actor_party_id(tenant_id)
    return nil if tenant_id.blank?
    return nil if Current.user&.party_id.blank?
    return nil unless Current.user&.tenant_id.to_s == tenant_id.to_s

    Current.user.party_id
  end

  def tenant_scoped_database_actor_id(tenant_id)
    tenant_scoped_audit_actor_party_id(tenant_id) || Current.user&.uuid_id || Current.actor_id
  end

  def tenant_scoped_audit_metadata(tenant_id:, metadata: {})
    normalized_metadata(
      {
        "admin_user_uuid_id" => Current.user&.uuid_id,
        "admin_user_role" => Current.user&.role,
        "admin_home_tenant_id" => Current.user&.tenant_id,
        "cross_tenant_admin_action" => Current.user&.tenant_id.to_s != tenant_id.to_s
      }.compact.merge(normalized_metadata(metadata))
    )
  end

  def normalized_metadata(raw_metadata)
    case raw_metadata
    when ActionController::Parameters
      normalized_metadata(raw_metadata.to_unsafe_h)
    when Hash
      raw_metadata.each_with_object({}) do |(key, value), output|
        output[key.to_s] = normalized_metadata(value)
      end
    when Array
      raw_metadata.map { |value| normalized_metadata(value) }
    else
      raw_metadata
    end
  end
end
