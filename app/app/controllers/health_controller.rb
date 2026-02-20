class HealthController < ActionController::API
  def health
    render json: {
      status: "ok",
      checks: {},
      timestamp: Time.current.iso8601
    }
  end

  def ready
    checks = database_checks

    if checks.values.all? { |status| status == "ok" }
      render json: {
        status: "ok",
        checks: checks,
        timestamp: Time.current.iso8601
      }
    else
      render json: {
        status: "error",
        checks: checks,
        timestamp: Time.current.iso8601
      }, status: :service_unavailable
    end
  end

  private

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
