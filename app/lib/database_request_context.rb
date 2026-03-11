module DatabaseRequestContext
  class Error < StandardError; end

  module_function

  APPLY_SQL = "SELECT app.set_request_context($1, $2, $3, $4, $5::boolean)".freeze
  SETTING_SQL = "SELECT set_config($1, $2, $3::boolean)".freeze

  def with(tenant_id:, actor_id: nil, role: nil, request_id: nil, local: true)
    ActiveRecord::Base.connection_pool.with_connection do
      checked_out_connection = connection
      if local && checked_out_connection.open_transactions.zero?
        ActiveRecord::Base.transaction(requires_new: true) do
          apply_on_connection!(
            checked_out_connection,
            tenant_id:,
            actor_id:,
            role:,
            request_id:,
            local: true
          )
          yield
        end
      else
        begin
          apply_on_connection!(
            checked_out_connection,
            tenant_id:,
            actor_id:,
            role:,
            request_id:,
            local: false
          )
          yield
        ensure
          clear_on_connection!(checked_out_connection, local: false)
        end
      end
    end
  end

  def apply!(tenant_id:, actor_id: nil, role: nil, request_id: nil, local: true)
    apply_on_connection!(
      connection,
      tenant_id:,
      actor_id:,
      role:,
      request_id:,
      local:
    )
  end

  def clear!(local: true)
    clear_on_connection!(connection, local:)
  end

  def set_setting!(key, value, local: true)
    exec_params!(
      connection,
      SETTING_SQL,
      [ key.to_s, value.to_s, local.to_s ],
      failure_message: "failed to apply database setting #{key}"
    )
  end

  def current_setting(key)
    ActiveRecord::Base.uncached do
      connection.select_value(
        "SELECT current_setting(#{connection.quote(key.to_s)}, true)"
      )
    end
  end

  def connection
    ActiveRecord::Base.connection
  end
  private_class_method :connection

  def apply_on_connection!(checked_out_connection, tenant_id:, actor_id: nil, role: nil, request_id: nil, local: true)
    exec_params!(
      checked_out_connection,
      APPLY_SQL,
      [
        tenant_id.to_s,
        actor_id.to_s,
        role.to_s,
        request_id.to_s,
        local.to_s
      ],
      failure_message: "failed to apply database request context"
    )
  end
  private_class_method :apply_on_connection!

  def clear_on_connection!(checked_out_connection, local: true)
    apply_on_connection!(
      checked_out_connection,
      tenant_id: nil,
      actor_id: nil,
      role: nil,
      request_id: nil,
      local:
    )
  end
  private_class_method :clear_on_connection!

  def exec_params!(checked_out_connection, sql, params, failure_message:)
    checked_out_connection.raw_connection.exec_params(sql, params)
    checked_out_connection.clear_query_cache
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid => error
    raise Error, "#{failure_message}: #{error.message}"
  end
  private_class_method :exec_params!
end
