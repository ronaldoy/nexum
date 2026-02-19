require "integrations/escrow/error"

module Integrations
  module Escrow
    module ProviderConfig
      module_function

      DEFAULT_PROVIDER = "QITECH".freeze
      SUPPORTED_PROVIDERS = %w[QITECH STARKBANK].freeze

      def default_provider(tenant_id:)
        tenant = Tenant.find_by(id: tenant_id)
        tenant_provider = tenant&.metadata&.dig("integrations", "escrow_provider")
        configured_provider = Rails.app.creds.option(
          :integrations,
          :escrow,
          :default_provider,
          default: ENV["ESCROW_DEFAULT_PROVIDER"]
        )

        normalize_provider(tenant_provider.presence || configured_provider.presence || DEFAULT_PROVIDER)
      end

      def normalize_provider(value)
        normalized = value.to_s.strip.upcase
        normalized = "QITECH" if normalized == "QI_TECH"
        normalized = "STARKBANK" if normalized == "STARK_BANK"

        return normalized if SUPPORTED_PROVIDERS.include?(normalized)

        raise UnsupportedProviderError.new(
          code: "unsupported_escrow_provider",
          message: "Unsupported escrow provider: #{value.inspect}",
          details: { provider: value }
        )
      end
    end
  end
end
