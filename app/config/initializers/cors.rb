allowed_origins = Array(
  Rails.app.creds.option(:security, :cors_allowed_origins, default: ENV["API_ALLOWED_ORIGINS"])
).flat_map { |value| value.to_s.split(",") }
 .map(&:strip)
 .reject(&:blank?)

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  if allowed_origins.any?
    allow do
      origins(*allowed_origins)

      resource "/api/*",
        headers: %w[Authorization Content-Type Idempotency-Key X-Request-Id],
        methods: %i[get post put patch delete options head],
        expose: %w[X-Request-Id],
        max_age: 600,
        credentials: false
    end
  end
end
