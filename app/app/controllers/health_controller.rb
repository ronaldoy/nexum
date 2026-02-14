class HealthController < ActionController::API
  def health
    render json: {
      status: "ok",
      checks: {},
      timestamp: Time.current.iso8601
    }
  end

  def ready
    ActiveRecord::Base.connection.execute("SELECT 1")

    render json: {
      status: "ok",
      checks: { database: "ok" },
      timestamp: Time.current.iso8601
    }
  rescue ActiveRecord::ActiveRecordError, PG::Error
    render json: {
      status: "error",
      checks: { database: "error" },
      timestamp: Time.current.iso8601
    }, status: :service_unavailable
  end
end
