require "test_helper"
require "integrations/escrow/error"

module Integrations
  module Escrow
    class ProviderConfigTest < ActiveSupport::TestCase
      test "defaults to qitech provider" do
        provider = ProviderConfig.default_provider(tenant_id: SecureRandom.uuid)

        assert_equal "QITECH", provider
      end

      test "rejects starkbank when v1 flag is disabled" do
        error = assert_raises(Integrations::Escrow::UnsupportedProviderError) do
          with_environment("ESCROW_ENABLE_STARKBANK" => nil) do
            ProviderConfig.normalize_provider("STARKBANK")
          end
        end

        assert_equal "escrow_provider_disabled_for_v1", error.code
      end

      test "allows starkbank when v1 flag is enabled" do
        provider = with_environment("ESCROW_ENABLE_STARKBANK" => "true") do
          ProviderConfig.normalize_provider("STARKBANK")
        end

        assert_equal "STARKBANK", provider
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
