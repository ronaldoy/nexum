# See: https://github.com/basecamp/upright
require Rails.root.join("lib/upright/auth_configuration")

upright_hostname =
  if Rails.env.local?
    ENV.fetch("UPRIGHT_HOSTNAME", "upright.localhost")
  else
    ENV.fetch("UPRIGHT_HOSTNAME")
  end
auth_configuration = Upright::AuthConfiguration.new

Upright.configure do |config|
  config.service_name = "nexum"
  config.user_agent   = "nexum-upright/1.0"
  config.hostname     = upright_hostname

  # Playwright browser server URL
  config.playwright_server_url = ENV["PLAYWRIGHT_SERVER_URL"] if ENV["PLAYWRIGHT_SERVER_URL"].present?

  # OpenTelemetry endpoint
  config.otel_endpoint = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].present?

  auth_configuration.configure_upright!(config)

  # Authentication via OpenID Connect (Logto, Keycloak, Duo, Okta, etc.)
  # To force static credentials in production for emergency access:
  # - set UPRIGHT_AUTH_PROVIDER=static_credentials
  # - set UPRIGHT_ALLOW_STATIC_AUTH_IN_PRODUCTION=true
end
