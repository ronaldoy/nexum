require "test_helper"
require "openssl"
require "integrations/escrow/error"

module Integrations
  module Escrow
    module Webhooks
      class AuthenticateRequestTest < ActiveSupport::TestCase
        RequestDouble = Struct.new(:headers, :authorization, keyword_init: true)
        TENANT_SLUG = "default".freeze

        test "accepts valid qitech hmac signature" do
          with_environment(qitech_secret_env => "test-secret") do
            body = '{"event_id":"evt-1"}'
            signature = OpenSSL::HMAC.hexdigest("SHA256", "test-secret", body)
            request = RequestDouble.new(headers: { "X-QITECH-Signature" => signature }, authorization: nil)

            result = AuthenticateRequest.new.call(
              provider: "QITECH",
              request: request,
              raw_body: body,
              tenant_slug: TENANT_SLUG
            )

            assert_equal signature, result
          end
        end

        test "rejects invalid qitech signature" do
          with_environment(qitech_secret_env => "test-secret") do
            request = RequestDouble.new(headers: { "X-QITECH-Signature" => "invalid" }, authorization: nil)

            error = assert_raises(AuthenticateRequest::Error) do
              AuthenticateRequest.new.call(
                provider: "QITECH",
                request: request,
                raw_body: "{}",
                tenant_slug: TENANT_SLUG
              )
            end

            assert_equal "webhook_signature_invalid", error.code
          end
        end

        test "accepts bearer token when token auth is configured" do
          with_environment(qitech_secret_env => nil, qitech_token_env => "token-123") do
            request = RequestDouble.new(headers: {}, authorization: "Bearer token-123")

            result = AuthenticateRequest.new.call(
              provider: "QITECH",
              request: request,
              raw_body: "{}",
              tenant_slug: TENANT_SLUG
            )

            assert_equal "bearer", result
          end
        end

        test "accepts provider token header when bearer token is absent" do
          with_environment(qitech_secret_env => nil, qitech_token_env => "header-token") do
            request = RequestDouble.new(headers: { "X-QITECH-Webhook-Token" => "header-token" }, authorization: nil)

            result = AuthenticateRequest.new.call(
              provider: "QITECH",
              request: request,
              raw_body: "{}",
              tenant_slug: TENANT_SLUG
            )

            assert_equal "bearer", result
          end
        end

        test "rejects starkbank while provider is disabled for v1" do
          with_environment("ESCROW_ENABLE_STARKBANK" => "false") do
            request = RequestDouble.new(headers: {}, authorization: nil)

            error = assert_raises(Integrations::Escrow::UnsupportedProviderError) do
              AuthenticateRequest.new.call(
                provider: "STARKBANK",
                request: request,
                raw_body: "{}",
                tenant_slug: TENANT_SLUG
              )
            end

            assert_equal "escrow_provider_disabled_for_v1", error.code
          end
        end

        test "rejects invalid webhook token" do
          with_environment(qitech_secret_env => nil, qitech_token_env => "token-123") do
            request = RequestDouble.new(headers: {}, authorization: "Bearer token-other")

            error = assert_raises(AuthenticateRequest::Error) do
              AuthenticateRequest.new.call(
                provider: "QITECH",
                request: request,
                raw_body: "{}",
                tenant_slug: TENANT_SLUG
              )
            end

            assert_equal "webhook_token_invalid", error.code
          end
        end

        test "requires auth configuration" do
          with_environment(qitech_secret_env => nil, qitech_token_env => nil) do
            request = RequestDouble.new(headers: {}, authorization: nil)

            error = assert_raises(AuthenticateRequest::Error) do
              AuthenticateRequest.new.call(
                provider: "QITECH",
                request: request,
                raw_body: "{}",
                tenant_slug: TENANT_SLUG
              )
            end

            assert_equal "webhook_auth_not_configured", error.code
          end
        end

        private

        def qitech_secret_env
          "QITECH_WEBHOOK_SECRET__#{TENANT_SLUG.upcase}"
        end

        def qitech_token_env
          "QITECH_WEBHOOK_TOKEN__#{TENANT_SLUG.upcase}"
        end

        def with_environment(overrides)
          previous = {}
          overrides.each_key { |key| previous[key] = ENV[key] }

          overrides.each do |key, value|
            if value.nil?
              ENV.delete(key)
            else
              ENV[key] = value
            end
          end

          yield
        ensure
          previous.each do |key, value|
            if value.nil?
              ENV.delete(key)
            else
              ENV[key] = value
            end
          end
        end
      end
    end
  end
end
