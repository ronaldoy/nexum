class HealthController < ActionController::API
  READY_TOKEN_HEADER = "X-Ready-Token".freeze

  before_action :authenticate_ready_probe!, only: :ready

  def health
    render_health_response
  end

  def ready
    checks = database_checks.merge(security_checks)
    render_readiness_response(checks)
  end

  private

  def authenticate_ready_probe!
    return if ready_probe_local_request?
    return if valid_ready_probe_token?

    head :not_found
  end

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

  def security_checks
    {
      "database_role" => Security::DatabaseRoleGuard.readiness_status,
      "database_schema" => Security::DatabaseSchemaAudit.readiness_status,
      "idempotency_conflicts" => Security::IdempotencyConflictMonitor.readiness_status,
      "payment_instruction_outbox" => Security::PaymentInstructionsOutboxMonitor.readiness_status
    }
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

  def ready_probe_local_request?
    request.local?
  end

  def valid_ready_probe_token?
    expected_token = ready_probe_token
    provided_token = request.headers[READY_TOKEN_HEADER].to_s.strip
    return false if expected_token.blank? || provided_token.blank?
    return false unless expected_token.bytesize == provided_token.bytesize

    ActiveSupport::SecurityUtils.secure_compare(provided_token, expected_token)
  end

  def ready_probe_token
    Rails.app.creds.option(:health, :ready_token, default: ENV["READY_CHECK_TOKEN"]).to_s.strip
  end
end
