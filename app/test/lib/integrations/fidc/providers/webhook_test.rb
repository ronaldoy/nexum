require "test_helper"
require "integrations/fidc/error"

module Integrations
  module Fidc
    module Providers
      class WebhookTest < ActiveSupport::TestCase
        test "rejects insecure http webhook base url" do
          provider = Webhook.new

          error = with_environment("FIDC_WEBHOOK_BASE_URL" => "http://fidc.example.test") do
            assert_raises(Integrations::Fidc::ConfigurationError) do
              provider.request_funding!(
                tenant_id: SecureRandom.uuid,
                anticipation_request: Struct.new(:id).new(SecureRandom.uuid),
                payload: {},
                idempotency_key: "fidc-http-base-url"
              )
            end
          end

          assert_equal "fidc_webhook_base_url_invalid", error.code
          assert_equal "must use HTTPS", error.details[:reason]
        end

        test "rejects webhook base url with embedded credentials" do
          provider = Webhook.new

          error = with_environment("FIDC_WEBHOOK_BASE_URL" => "https://user:pass@fidc.example.test") do
            assert_raises(Integrations::Fidc::ConfigurationError) do
              provider.report_settlement!(
                tenant_id: SecureRandom.uuid,
                settlement: Struct.new(:id).new(SecureRandom.uuid),
                payload: {},
                idempotency_key: "fidc-userinfo-base-url"
              )
            end
          end

          assert_equal "fidc_webhook_base_url_invalid", error.code
          assert_equal "must not include userinfo", error.details[:reason]
        end

        test "requires outbound bearer token" do
          provider = Webhook.new

          error = with_environment(
            "FIDC_WEBHOOK_BASE_URL" => "https://fidc.example.test",
            "FIDC_WEBHOOK_BEARER_TOKEN" => nil
          ) do
            assert_raises(Integrations::Fidc::ConfigurationError) do
              provider.request_funding!(
                tenant_id: SecureRandom.uuid,
                anticipation_request: Struct.new(:id).new(SecureRandom.uuid),
                payload: {},
                idempotency_key: "fidc-missing-bearer-token"
              )
            end
          end

          assert_equal "fidc_webhook_bearer_token_missing", error.code
        end

        private

        def with_environment(overrides)
          previous = {}
          overrides.each do |key, value|
            previous[key] = ENV[key]
            value.nil? ? ENV.delete(key) : ENV[key] = value
          end
          yield
        ensure
          previous.each do |key, value|
            value.nil? ? ENV.delete(key) : ENV[key] = value
          end
        end
      end
    end
  end
end
