WebAuthn.configure do |config|
  configured_origins = Rails.app.creds.option(:security, :webauthn_allowed_origins, default: ENV["WEBAUTHN_ALLOWED_ORIGINS"])
  configured_origins = Array(configured_origins).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?)

  config.allowed_origins = configured_origins.presence || [
    "http://localhost:3000",
    "http://127.0.0.1:3000",
    "http://www.example.com"
  ]

  config.rp_name = Rails.app.creds.option(:security, :webauthn_rp_name, default: ENV["WEBAUTHN_RP_NAME"]).presence || "Nexum Capital"
end
