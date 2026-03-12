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

            assert_equal signature, result.signature
            assert_nil result.event
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
          with_environment(
            qitech_secret_env => nil,
            qitech_token_env => "token-123",
            qitech_insecure_token_auth_env => "true"
          ) do
            request = RequestDouble.new(headers: {}, authorization: "Bearer token-123")

            result = AuthenticateRequest.new.call(
              provider: "QITECH",
              request: request,
              raw_body: "{}",
              tenant_slug: TENANT_SLUG
            )

            assert_equal "bearer", result.signature
            assert_nil result.event
          end
        end

        test "accepts provider token header when bearer token is absent" do
          with_environment(
            qitech_secret_env => nil,
            qitech_token_env => "header-token",
            qitech_insecure_token_auth_env => "true"
          ) do
            request = RequestDouble.new(headers: { "X-QITECH-Webhook-Token" => "header-token" }, authorization: nil)

            result = AuthenticateRequest.new.call(
              provider: "QITECH",
              request: request,
              raw_body: "{}",
              tenant_slug: TENANT_SLUG
            )

            assert_equal "bearer", result.signature
            assert_nil result.event
          end
        end

        test "accepts valid starkbank digital signature" do
          event = Struct.new(:id).new("evt-stark-1")
          organization_user = Object.new
          parse_arguments = nil

          with_environment(
            starkbank_organization_id_env => "organization-123",
            starkbank_organization_private_key_env => "private-key"
          ) do
            request = RequestDouble.new(headers: { "Digital-Signature" => "stark-signature" }, authorization: nil)

            with_singleton_method_stub(Integrations::Escrow::Providers::StarkBankConfiguration, :organization_user, ->(**) { organization_user }) do
              with_singleton_method_stub(::StarkBank::Event, :parse, ->(content:, signature:, user:) {
                parse_arguments = { content: content, signature: signature, user: user }
                event
              }) do
                result = AuthenticateRequest.new.call(
                  provider: "STARKBANK",
                  request: request,
                  raw_body: '{"event_id":"evt-stark-1"}',
                  tenant_slug: TENANT_SLUG
                )

                assert_equal "stark-signature", result.signature
                assert_same event, result.event
              end
            end
          end

          assert_equal(
            {
              content: '{"event_id":"evt-stark-1"}',
              signature: "stark-signature",
              user: organization_user
            },
            parse_arguments
          )
        end

        test "rejects invalid starkbank digital signature" do
          invalid_signature_error = ::StarkCore::Error::InvalidSignatureError.new("invalid signature")

          with_environment(
            starkbank_organization_id_env => "organization-123",
            starkbank_organization_private_key_env => "private-key"
          ) do
            request = RequestDouble.new(headers: { "Digital-Signature" => "bad-signature" }, authorization: nil)

            with_singleton_method_stub(Integrations::Escrow::Providers::StarkBankConfiguration, :organization_user, ->(**) { Object.new }) do
              with_singleton_method_stub(::StarkBank::Event, :parse, ->(content:, signature:, user:) {
                raise invalid_signature_error
              }) do
                error = assert_raises(AuthenticateRequest::Error) do
                  AuthenticateRequest.new.call(
                    provider: "STARKBANK",
                    request: request,
                    raw_body: '{"event_id":"evt-stark-1"}',
                    tenant_slug: TENANT_SLUG
                  )
                end

                assert_equal "webhook_signature_invalid", error.code
              end
            end
          end
        end

        test "rejects starkbank while provider is disabled for v1" do
          with_environment(
            "ESCROW_ENABLE_STARKBANK" => "false",
            starkbank_organization_id_env => nil,
            starkbank_organization_private_key_env => nil
          ) do
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
          with_environment(
            qitech_secret_env => nil,
            qitech_token_env => "token-123",
            qitech_insecure_token_auth_env => "true"
          ) do
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

        test "rejects token auth unless insecure token auth is explicitly enabled" do
          with_environment(qitech_secret_env => nil, qitech_token_env => "token-123", qitech_insecure_token_auth_env => nil) do
            request = RequestDouble.new(headers: {}, authorization: "Bearer token-123")

            error = assert_raises(AuthenticateRequest::Error) do
              AuthenticateRequest.new.call(
                provider: "QITECH",
                request: request,
                raw_body: "{}",
                tenant_slug: TENANT_SLUG
              )
            end

            assert_equal "webhook_insecure_token_auth_disabled", error.code
          end
        end

        test "requires auth configuration" do
          with_environment(qitech_secret_env => nil, qitech_token_env => nil, qitech_insecure_token_auth_env => nil) do
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

        test "does not use env-backed webhook secrets for unsafe tenant slugs" do
          with_environment("QITECH_WEBHOOK_SECRET__ACME_BANK" => "test-secret") do
            body = '{"event_id":"evt-unsafe-tenant"}'
            signature = OpenSSL::HMAC.hexdigest("SHA256", "test-secret", body)
            request = RequestDouble.new(headers: { "X-QITECH-Signature" => signature }, authorization: nil)

            error = assert_raises(AuthenticateRequest::Error) do
              AuthenticateRequest.new.call(
                provider: "QITECH",
                request: request,
                raw_body: body,
                tenant_slug: "acme_bank"
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

        def qitech_insecure_token_auth_env
          "QITECH_WEBHOOK_ALLOW_INSECURE_TOKEN_AUTH__#{TENANT_SLUG.upcase}"
        end

        def starkbank_organization_id_env
          "STARKBANK_ORGANIZATION_ID__#{TENANT_SLUG.upcase}"
        end

        def starkbank_organization_private_key_env
          "STARKBANK_ORGANIZATION_PRIVATE_KEY__#{TENANT_SLUG.upcase}"
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

        def with_singleton_method_stub(object, method_name, implementation)
          singleton_class = class << object
            self
          end
          original_method = singleton_class.instance_method(method_name)
          singleton_class.define_method(method_name, implementation)
          yield
        ensure
          singleton_class.define_method(method_name, original_method) if original_method
        end
      end
    end
  end
end
