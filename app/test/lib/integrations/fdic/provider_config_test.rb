require "test_helper"
require "integrations/fdic/error"

module Integrations
  module Fdic
    class ProviderConfigTest < ActiveSupport::TestCase
      test "falls back to mock provider outside production" do
        provider = with_rails_env("test") do
          ProviderConfig.default_provider(tenant_id: SecureRandom.uuid)
        end

        assert_equal "MOCK", provider
      end

      test "falls back to webhook provider in production" do
        provider = with_rails_env("production") do
          ProviderConfig.default_provider(tenant_id: SecureRandom.uuid)
        end

        assert_equal "WEBHOOK", provider
      end

      test "rejects mock provider in production by default" do
        error = assert_raises(Integrations::Fdic::UnsupportedProviderError) do
          with_rails_env("production") do
            ProviderConfig.normalize_provider("MOCK")
          end
        end

        assert_equal "fdic_provider_unsafe_for_production", error.code
      end

      test "allows mock provider in production only with explicit override" do
        provider = with_environment("FDIC_ALLOW_MOCK_IN_PRODUCTION" => "true") do
          with_rails_env("production") do
            ProviderConfig.normalize_provider("MOCK")
          end
        end

        assert_equal "MOCK", provider
      end

      private

      def with_rails_env(value)
        original_env_method = Rails.method(:env)
        Rails.define_singleton_method(:env) { ActiveSupport::StringInquirer.new(value) }
        yield
      ensure
        Rails.define_singleton_method(:env, original_env_method)
      end

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
