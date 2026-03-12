require "bigdecimal"
require "starkbank"

module Integrations
  module Escrow
    module Providers
      module StarkBankConfiguration
        DEFAULT_ENVIRONMENT = "sandbox".freeze
        DEFAULT_RISK_LIMIT = BigDecimal("100000.00")

        module_function

        def organization_user(tenant_id: nil, tenant_slug: nil, workspace_id: nil)
          ::StarkBank::Organization.new(
            environment: environment_for(tenant_id:, tenant_slug:),
            id: organization_id_for(tenant_id:, tenant_slug:),
            private_key: organization_private_key_for(tenant_id:, tenant_slug:),
            workspace_id: workspace_id
          )
        end

        def workspace_user(workspace_id:, tenant_id: nil, tenant_slug: nil)
          organization = organization_user(tenant_id:, tenant_slug:, workspace_id: nil)
          ::StarkBank::Organization.replace(organization, workspace_id)
        end

        def source_workspace_id_for(tenant_id: nil, tenant_slug: nil)
          value = scoped_option(
            tenant_id:,
            tenant_slug:,
            key: :source_workspace_id,
            env_key: "STARKBANK_SOURCE_WORKSPACE_ID"
          ).to_s.strip
          raise_configuration!("starkbank_source_workspace_id_missing", "Stark Bank source workspace id is missing.") if value.blank?

          value
        end

        def risk_limit_amount_for(tenant_id: nil, tenant_slug: nil)
          raw_value = scoped_option(
            tenant_id:,
            tenant_slug:,
            key: :risk_limit_brl,
            env_key: "STARKBANK_RISK_LIMIT_BRL"
          )

          return DEFAULT_RISK_LIMIT if raw_value.blank?

          value = BigDecimal(raw_value.to_s)
          return value if value.positive?

          raise_configuration!("starkbank_risk_limit_invalid", "Stark Bank risk limit must be greater than zero.")
        rescue ArgumentError
          raise_configuration!("starkbank_risk_limit_invalid", "Stark Bank risk limit must be a valid decimal.")
        end

        def environment_for(tenant_id: nil, tenant_slug: nil)
          scoped_option(
            tenant_id:,
            tenant_slug:,
            key: :environment,
            env_key: "STARKBANK_ENVIRONMENT"
          ).to_s.strip.presence || DEFAULT_ENVIRONMENT
        end

        def organization_id_for(tenant_id: nil, tenant_slug: nil)
          value = scoped_option(
            tenant_id:,
            tenant_slug:,
            key: :organization_id,
            env_key: "STARKBANK_ORGANIZATION_ID"
          ).to_s.strip
          raise_configuration!("starkbank_organization_id_missing", "Stark Bank organization id is missing.") if value.blank?

          value
        end

        def organization_private_key_for(tenant_id: nil, tenant_slug: nil)
          value = scoped_option(
            tenant_id:,
            tenant_slug:,
            key: :organization_private_key,
            env_key: "STARKBANK_ORGANIZATION_PRIVATE_KEY"
          ).to_s.gsub("\\n", "\n")
          raise_configuration!("starkbank_organization_private_key_missing", "Stark Bank organization private key is missing.") if value.blank?

          value
        end

        def tenant_slug_for(tenant_id: nil, tenant_slug: nil)
          normalized_slug = tenant_slug.to_s.strip.downcase
          return normalized_slug if normalized_slug.present?
          return nil if tenant_id.blank?

          Tenant.unscoped.where(id: tenant_id).pick(:slug).to_s.strip.downcase.presence
        end

        def scoped_option(tenant_id:, tenant_slug:, key:, env_key:)
          normalized_slug = tenant_slug_for(tenant_id:, tenant_slug:)
          tenant_key = normalized_slug.presence

          if tenant_key.present?
            tenant_specific = Rails.app.creds.option(
              :integrations,
              :starkbank,
              :tenants,
              tenant_key,
              key,
              default: tenant_scoped_env_value(env_key:, tenant_slug: tenant_key)
            )
            return tenant_specific unless tenant_specific.nil? || tenant_specific == ""
          end

          Rails.app.creds.option(:integrations, :starkbank, key, default: ENV[env_key])
        end

        def tenant_scoped_env_value(env_key:, tenant_slug:)
          return nil unless Tenant::SLUG_FORMAT.match?(tenant_slug.to_s)

          normalized_slug = tenant_slug.to_s.upcase.gsub(/[^A-Z0-9]+/, "_")
          ENV["#{env_key}__#{normalized_slug}"]
        end

        def raise_configuration!(code, message)
          raise ConfigurationError.new(code:, message:)
        end
      end
    end
  end
end
