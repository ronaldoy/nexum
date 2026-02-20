require "integrations/escrow/error"

module Integrations
  module Escrow
    module ProviderConfig
      module_function

      DEFAULT_PROVIDER = "QITECH".freeze
      SUPPORTED_PROVIDERS = %w[QITECH STARKBANK].freeze
      STARKBANK_ENABLE_FLAG = "ESCROW_ENABLE_STARKBANK".freeze

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

        if SUPPORTED_PROVIDERS.include?(normalized)
          enforce_provider_safety!(normalized)
          return normalized
        end

        raise UnsupportedProviderError.new(
          code: "unsupported_escrow_provider",
          message: "Unsupported escrow provider: #{value.inspect}",
          details: { provider: value }
        )
      end

      def enforce_provider_safety!(provider)
        return unless provider == "STARKBANK"
        return if starkbank_enabled?

        raise UnsupportedProviderError.new(
          code: "escrow_provider_disabled_for_v1",
          message: "Escrow provider STARKBANK is disabled for v1.",
          details: {
            provider: provider,
            enable_flag: STARKBANK_ENABLE_FLAG
          }
        )
      end

      def starkbank_enabled?
        configured = Rails.app.creds.option(
          :integrations,
          :escrow,
          :enable_starkbank,
          default: ENV[STARKBANK_ENABLE_FLAG]
        )

        ActiveModel::Type::Boolean.new.cast(configured)
      end
    end
  end
end
