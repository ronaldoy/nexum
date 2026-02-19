require "test_helper"
require "openssl"

module Integrations
  module Escrow
    module Webhooks
      class AuthenticateRequestTest < ActiveSupport::TestCase
        RequestDouble = Struct.new(:headers, :authorization, keyword_init: true)

        test "accepts valid qitech hmac signature" do
          with_environment("QITECH_WEBHOOK_SECRET" => "test-secret") do
            body = '{"event_id":"evt-1"}'
            signature = OpenSSL::HMAC.hexdigest("SHA256", "test-secret", body)
            request = RequestDouble.new(headers: { "X-QITECH-Signature" => signature }, authorization: nil)

            result = AuthenticateRequest.new.call(provider: "QITECH", request: request, raw_body: body)

            assert_equal signature, result
          end
        end

        test "rejects invalid qitech signature" do
          with_environment("QITECH_WEBHOOK_SECRET" => "test-secret") do
            request = RequestDouble.new(headers: { "X-QITECH-Signature" => "invalid" }, authorization: nil)

            error = assert_raises(AuthenticateRequest::Error) do
              AuthenticateRequest.new.call(provider: "QITECH", request: request, raw_body: "{}")
            end

            assert_equal "webhook_signature_invalid", error.code
          end
        end

        test "requires auth configuration" do
          with_environment("QITECH_WEBHOOK_SECRET" => nil, "QITECH_WEBHOOK_TOKEN" => nil) do
            request = RequestDouble.new(headers: {}, authorization: nil)

            error = assert_raises(AuthenticateRequest::Error) do
              AuthenticateRequest.new.call(provider: "QITECH", request: request, raw_body: "{}")
            end

            assert_equal "webhook_auth_not_configured", error.code
          end
        end

        private

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
