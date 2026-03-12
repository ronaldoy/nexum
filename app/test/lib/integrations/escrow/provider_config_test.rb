require "test_helper"
require "integrations/escrow/error"

module Integrations
  module Escrow
    class ProviderConfigTest < ActiveSupport::TestCase
      setup do
        @tenant = tenants(:default)
      end

      test "defaults to qitech provider" do
        provider = with_environment(
          "STARKBANK_ORGANIZATION_ID" => nil,
          "STARKBANK_ORGANIZATION_PRIVATE_KEY" => nil
        ) do
          ProviderConfig.default_provider(tenant_id: SecureRandom.uuid)
        end

        assert_equal "QITECH", provider
      end

      test "rejects starkbank when v1 flag is disabled" do
        error = assert_raises(Integrations::Escrow::UnsupportedProviderError) do
          with_environment(
            "ESCROW_ENABLE_STARKBANK" => nil,
            "STARKBANK_ORGANIZATION_ID" => nil,
            "STARKBANK_ORGANIZATION_PRIVATE_KEY" => nil
          ) do
            ProviderConfig.normalize_provider("STARKBANK")
          end
        end

        assert_equal "escrow_provider_disabled_for_v1", error.code
      end

      test "allows starkbank when v1 flag is enabled" do
        provider = with_environment(
          "ESCROW_ENABLE_STARKBANK" => "true",
          "STARKBANK_ORGANIZATION_ID" => nil,
          "STARKBANK_ORGANIZATION_PRIVATE_KEY" => nil
        ) do
          ProviderConfig.normalize_provider("STARKBANK")
        end

        assert_equal "STARKBANK", provider
      end

      test "defaults to starkbank when organization credentials are configured" do
        provider = with_environment(
          "ESCROW_ENABLE_STARKBANK" => nil,
          "STARKBANK_ORGANIZATION_ID" => "organization-123",
          "STARKBANK_ORGANIZATION_PRIVATE_KEY" => "private-key"
        ) do
          ProviderConfig.default_provider(tenant_id: SecureRandom.uuid)
        end

        assert_equal "STARKBANK", provider
      end

      test "allows starkbank when organization credentials are configured" do
        provider = with_environment(
          "ESCROW_ENABLE_STARKBANK" => nil,
          "STARKBANK_ORGANIZATION_ID" => "organization-123",
          "STARKBANK_ORGANIZATION_PRIVATE_KEY" => "private-key"
        ) do
          ProviderConfig.normalize_provider("STARKBANK")
        end

        assert_equal "STARKBANK", provider
      end

      test "allows starkbank when tenant-scoped credentials are configured" do
        provider = with_environment(
          "ESCROW_ENABLE_STARKBANK" => nil,
          "STARKBANK_ORGANIZATION_ID" => nil,
          "STARKBANK_ORGANIZATION_PRIVATE_KEY" => nil,
          "STARKBANK_ORGANIZATION_ID__DEFAULT" => "organization-tenant",
          "STARKBANK_ORGANIZATION_PRIVATE_KEY__DEFAULT" => "tenant-private-key"
        ) do
          ProviderConfig.normalize_provider("STARKBANK", tenant_id: @tenant.id)
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
