# frozen_string_literal: true

module Upright
  class AuthConfiguration
    OIDC_PROVIDER = :openid_connect
    STATIC_PROVIDER = :static_credentials
    SUPPORTED_PROVIDERS = [ OIDC_PROVIDER, STATIC_PROVIDER ].freeze
    OIDC_REQUIRED_ENV = %w[OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET].freeze

    def initialize(env: ENV, rails_env: Rails.env)
      @env = env
      @rails_env = rails_env.to_s
    end

    def provider
      selected = @env.fetch("UPRIGHT_AUTH_PROVIDER", default_provider).to_s
      symbol = selected.to_sym

      return symbol if SUPPORTED_PROVIDERS.include?(symbol)

      raise ArgumentError, "Unsupported UPRIGHT_AUTH_PROVIDER: #{selected.inspect}"
    end

    def configure_upright!(config)
      config.auth_provider = provider
      config.auth_options = provider == OIDC_PROVIDER ? openid_connect_options : {}
    end

    def openid_connect_options
      missing = OIDC_REQUIRED_ENV.select { |key| @env[key].blank? }
      if missing.any?
        raise ArgumentError, "Missing OIDC configuration: #{missing.join(', ')}"
      end

      {
        issuer: @env.fetch("OIDC_ISSUER"),
        discovery: true,
        response_type: :code,
        scope: %i[openid email profile],
        client_options: {
          identifier: @env.fetch("OIDC_CLIENT_ID"),
          secret: @env.fetch("OIDC_CLIENT_SECRET")
        }
      }
    end

    def static_credentials
      if production? && !allow_static_auth_in_production?
        raise ArgumentError, "Static credentials are disabled in production. Configure OIDC instead."
      end

      username = @env.fetch("ADMIN_USERNAME", "admin")
      password = @env.fetch("ADMIN_PASSWORD", local? ? "upright" : nil)

      if production? && (password.blank? || password == "upright")
        raise ArgumentError, "Set ADMIN_PASSWORD to a non-default value in production."
      end

      { username: username, password: password.presence || "upright" }
    end

    private

    def default_provider
      production? ? OIDC_PROVIDER.to_s : STATIC_PROVIDER.to_s
    end

    def production?
      @rails_env == "production"
    end

    def local?
      @rails_env.in?(%w[development test])
    end

    def allow_static_auth_in_production?
      ActiveModel::Type::Boolean.new.cast(@env["UPRIGHT_ALLOW_STATIC_AUTH_IN_PRODUCTION"])
    end
  end
end
