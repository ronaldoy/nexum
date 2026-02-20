# See: https://github.com/basecamp/upright

upright_hostname =
  if Rails.env.local?
    ENV.fetch("UPRIGHT_HOSTNAME", "upright.localhost")
  else
    ENV.fetch("UPRIGHT_HOSTNAME")
  end

Upright.configure do |config|
  config.service_name = "nexum"
  config.user_agent   = "nexum-upright/1.0"
  config.hostname     = upright_hostname

  # Playwright browser server URL
  config.playwright_server_url = ENV["PLAYWRIGHT_SERVER_URL"] if ENV["PLAYWRIGHT_SERVER_URL"].present?

  # OpenTelemetry endpoint
  config.otel_endpoint = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].present?

  # Authentication via OpenID Connect (Logto, Keycloak, Duo, Okta, etc.)
  # config.auth_provider = :openid_connect
  # config.auth_options = {
  #   issuer: ENV["OIDC_ISSUER"],
  #   client_id: ENV["OIDC_CLIENT_ID"],
  #   client_secret: ENV["OIDC_CLIENT_SECRET"]
  # }
end
