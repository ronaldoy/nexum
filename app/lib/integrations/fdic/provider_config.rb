require "integrations/fdic/error"

module Integrations
  module Fdic
    module ProviderConfig
      module_function

      DEFAULT_PROVIDER = "MOCK".freeze
      PRODUCTION_DEFAULT_PROVIDER = "WEBHOOK".freeze
      SUPPORTED_PROVIDERS = %w[MOCK WEBHOOK].freeze

      def default_provider(tenant_id:)
        tenant = Tenant.find_by(id: tenant_id)
        tenant_provider = tenant&.metadata&.dig("integrations", "fdic_provider")
        configured_provider = Rails.app.creds.option(
          :integrations,
          :fdic,
          :default_provider,
          default: ENV["FDIC_DEFAULT_PROVIDER"]
        )

        normalize_provider(tenant_provider.presence || configured_provider.presence || fallback_provider)
      end

      def normalize_provider(value)
        normalized = value.to_s.strip.upcase
        normalized = "WEBHOOK" if normalized == "HTTP"

        if SUPPORTED_PROVIDERS.include?(normalized)
          enforce_provider_safety!(normalized)
          return normalized
        end

        raise UnsupportedProviderError.new(
          code: "unsupported_fdic_provider",
          message: "Unsupported FIDC provider: #{value.inspect}",
          details: { provider: value }
        )
      end

      def fallback_provider
        Rails.env.production? ? PRODUCTION_DEFAULT_PROVIDER : DEFAULT_PROVIDER
      end

      def enforce_provider_safety!(provider)
        return unless provider == "MOCK"
        return unless Rails.env.production?
        return if allow_mock_in_production?

        raise UnsupportedProviderError.new(
          code: "fdic_provider_unsafe_for_production",
          message: "FDIC provider MOCK is not allowed in production.",
          details: { provider: provider }
        )
      end

      def allow_mock_in_production?
        configured = Rails.app.creds.option(
          :integrations,
          :fdic,
          :allow_mock_in_production,
          default: ENV["FDIC_ALLOW_MOCK_IN_PRODUCTION"]
        )

        ActiveModel::Type::Boolean.new.cast(configured)
      end
    end
  end
end
