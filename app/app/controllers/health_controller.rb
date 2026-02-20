class HealthController < ActionController::API
  def health
    render_health_response
  end

  def ready
    checks = database_checks
    render_readiness_response(checks)
  end

  private

  def render_health_response
    render json: health_payload(checks: {})
  end

  def render_readiness_response(checks)
    overall_status = readiness_status(checks)
    render_status = overall_status == "ok" ? :ok : :service_unavailable

    render json: health_payload(checks: checks, status: overall_status), status: render_status
  end

  def readiness_status(checks)
    checks.values.all? { |status| status == "ok" } ? "ok" : "error"
  end

  def health_payload(checks:, status: "ok")
    {
      status: status,
      checks: checks,
      timestamp: Time.current.iso8601
    }
  end

  def database_checks
    postgres_configs.each_with_object({}) do |db_config, output|
      output[db_config.name.to_s] = postgres_ready?(db_config) ? "ok" : "error"
    end
  end

  def postgres_configs
    configs = ActiveRecord::Base.configurations
      .configs_for(env_name: Rails.env)
      .select { |config| config.adapter == "postgresql" }

    return configs if configs.any?

    [ ActiveRecord::Base.connection_db_config ]
  end

  def postgres_ready?(db_config)
    connection = PG.connect(postgres_connection_params(db_config))
    connection.exec("SELECT 1")
    true
  rescue PG::Error
    false
  ensure
    connection&.close
  end

  def postgres_connection_params(db_config)
    config = db_config.configuration_hash.symbolize_keys

    {
      dbname: config.fetch(:database),
      host: config[:host],
      port: config[:port],
      user: config[:username],
      password: config[:password],
      connect_timeout: 2
    }.compact
  end
end
