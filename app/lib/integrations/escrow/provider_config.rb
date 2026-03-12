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

        fallback_provider = starkbank_ready?(tenant_slug: tenant&.slug) ? "STARKBANK" : DEFAULT_PROVIDER

        normalize_provider(
          tenant_provider.presence || configured_provider.presence || fallback_provider,
          tenant_id: tenant_id,
          tenant_slug: tenant&.slug
        )
      end

      def normalize_provider(value, tenant_id: nil, tenant_slug: nil)
        normalized = value.to_s.strip.upcase
        normalized = "QITECH" if normalized == "QI_TECH"
        normalized = "STARKBANK" if normalized == "STARK_BANK"

        if SUPPORTED_PROVIDERS.include?(normalized)
          enforce_provider_safety!(normalized, tenant_id:, tenant_slug:)
          return normalized
        end

        raise UnsupportedProviderError.new(
          code: "unsupported_escrow_provider",
          message: "Unsupported escrow provider: #{value.inspect}",
          details: { provider: value }
        )
      end

      def enforce_provider_safety!(provider, tenant_id: nil, tenant_slug: nil)
        return unless provider == "STARKBANK"
        return if starkbank_enabled?(tenant_id:, tenant_slug:)

        raise UnsupportedProviderError.new(
          code: "escrow_provider_disabled_for_v1",
          message: "Escrow provider STARKBANK is disabled for v1.",
          details: {
            provider: provider,
            enable_flag: STARKBANK_ENABLE_FLAG
          }
        )
      end

      def starkbank_enabled?(tenant_id: nil, tenant_slug: nil)
        configured = Rails.app.creds.option(
          :integrations,
          :escrow,
          :enable_starkbank,
          default: ENV[STARKBANK_ENABLE_FLAG]
        )

        ActiveModel::Type::Boolean.new.cast(configured) || starkbank_ready?(tenant_id:, tenant_slug:)
      end

      def starkbank_ready?(tenant_id: nil, tenant_slug: nil)
        tenant_key = tenant_slug_for(tenant_id:, tenant_slug:)
        organization_id = if tenant_key.present?
          Rails.app.creds.option(
            :integrations,
            :starkbank,
            :tenants,
            tenant_key,
            :organization_id,
            default: tenant_scoped_env_value(base_key: "STARKBANK_ORGANIZATION_ID", tenant_slug: tenant_key)
          )
        end
        organization_id ||= Rails.app.creds.option(:integrations, :starkbank, :organization_id, default: ENV["STARKBANK_ORGANIZATION_ID"])
        private_key = if tenant_key.present?
          Rails.app.creds.option(
            :integrations,
            :starkbank,
            :tenants,
            tenant_key,
            :organization_private_key,
            default: tenant_scoped_env_value(base_key: "STARKBANK_ORGANIZATION_PRIVATE_KEY", tenant_slug: tenant_key)
          )
        end
        private_key ||= Rails.app.creds.option(:integrations, :starkbank, :organization_private_key, default: ENV["STARKBANK_ORGANIZATION_PRIVATE_KEY"])

        organization_id.to_s.strip.present? && private_key.to_s.strip.present?
      end

      def tenant_slug_for(tenant_id: nil, tenant_slug: nil)
        normalized_slug = tenant_slug.to_s.strip.downcase
        return normalized_slug if normalized_slug.present?
        return nil if tenant_id.blank?

        Tenant.find_by(id: tenant_id)&.slug.to_s.strip.downcase.presence
      end

      def tenant_scoped_env_value(base_key:, tenant_slug:)
        return nil unless Tenant::SLUG_FORMAT.match?(tenant_slug.to_s)

        normalized_slug = tenant_slug.to_s.upcase.gsub(/[^A-Z0-9]+/, "_")
        ENV["#{base_key}__#{normalized_slug}"]
      end
    end
  end
end
