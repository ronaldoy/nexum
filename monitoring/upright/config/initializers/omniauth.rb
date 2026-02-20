require Rails.root.join("lib/upright/auth_configuration")

auth_configuration = Upright::AuthConfiguration.new

Rails.application.config.middleware.use OmniAuth::Builder do
  if auth_configuration.provider == Upright::AuthConfiguration::OIDC_PROVIDER
    provider Upright::AuthConfiguration::OIDC_PROVIDER, **auth_configuration.openid_connect_options
  else
    credentials = auth_configuration.static_credentials
    provider Upright::AuthConfiguration::STATIC_PROVIDER,
      title: "Sign In",
      credentials: { credentials.fetch(:username) => credentials.fetch(:password) }
  end
end
