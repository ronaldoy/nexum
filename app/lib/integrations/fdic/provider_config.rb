require "integrations/fdic/error"

module Integrations
  module Fdic
    module ProviderConfig
      module_function

      DEFAULT_PROVIDER = "MOCK".freeze
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

        normalize_provider(tenant_provider.presence || configured_provider.presence || DEFAULT_PROVIDER)
      end

      def normalize_provider(value)
        normalized = value.to_s.strip.upcase
        normalized = "WEBHOOK" if normalized == "HTTP"

        return normalized if SUPPORTED_PROVIDERS.include?(normalized)

        raise UnsupportedProviderError.new(
          code: "unsupported_fdic_provider",
          message: "Unsupported FIDC provider: #{value.inspect}",
          details: { provider: value }
        )
      end
    end
  end
end
