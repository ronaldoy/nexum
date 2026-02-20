require "test_helper"

module Upright
  class AuthConfigurationTest < ActiveSupport::TestCase
    test "development defaults to static credentials provider" do
      config = AuthConfiguration.new(env: {}, rails_env: "development")

      assert_equal :static_credentials, config.provider
      assert_equal({ username: "admin", password: "upright" }, config.static_credentials)
    end

    test "production defaults to openid connect provider" do
      config = AuthConfiguration.new(env: {}, rails_env: "production")

      assert_equal :openid_connect, config.provider
    end

    test "openid connect options require issuer client id and client secret" do
      config = AuthConfiguration.new(env: {}, rails_env: "production")

      error = assert_raises(ArgumentError) { config.openid_connect_options }

      assert_includes error.message, "Missing OIDC configuration"
      assert_includes error.message, "OIDC_ISSUER"
      assert_includes error.message, "OIDC_CLIENT_ID"
      assert_includes error.message, "OIDC_CLIENT_SECRET"
    end

    test "builds openid connect options when required variables are provided" do
      env = {
        "OIDC_ISSUER" => "https://issuer.example.com",
        "OIDC_CLIENT_ID" => "client-id",
        "OIDC_CLIENT_SECRET" => "client-secret"
      }
      config = AuthConfiguration.new(env: env, rails_env: "production")

      options = config.openid_connect_options

      assert_equal "https://issuer.example.com", options.fetch(:issuer)
      assert_equal true, options.fetch(:discovery)
      assert_equal :code, options.fetch(:response_type)
      assert_equal %i[openid email profile], options.fetch(:scope)
      assert_equal "client-id", options.dig(:client_options, :identifier)
      assert_equal "client-secret", options.dig(:client_options, :secret)
    end

    test "rejects unsupported provider configuration" do
      config = AuthConfiguration.new(
        env: { "UPRIGHT_AUTH_PROVIDER" => "magic" },
        rails_env: "development"
      )

      error = assert_raises(ArgumentError) { config.provider }

      assert_includes error.message, "Unsupported UPRIGHT_AUTH_PROVIDER"
    end

    test "blocks static credentials in production unless explicitly allowed" do
      config = AuthConfiguration.new(
        env: {
          "UPRIGHT_AUTH_PROVIDER" => "static_credentials",
          "ADMIN_PASSWORD" => "super-secret"
        },
        rails_env: "production"
      )

      error = assert_raises(ArgumentError) { config.static_credentials }

      assert_includes error.message, "disabled in production"
    end

    test "allows static credentials in production with explicit override" do
      config = AuthConfiguration.new(
        env: {
          "UPRIGHT_AUTH_PROVIDER" => "static_credentials",
          "UPRIGHT_ALLOW_STATIC_AUTH_IN_PRODUCTION" => "true",
          "ADMIN_USERNAME" => "ops",
          "ADMIN_PASSWORD" => "super-secret"
        },
        rails_env: "production"
      )

      assert_equal({ username: "ops", password: "super-secret" }, config.static_credentials)
    end
  end
end
