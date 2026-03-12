module Integrations
  module Escrow
    class ResolveOperationalProvider
      def call(tenant_id:, party:, requested_provider_code: nil)
        active_provider = EscrowAccount.active.where(
          tenant_id: tenant_id,
          party_id: party.id
        ).order(updated_at: :desc).pick(:provider)
        return ProviderConfig.normalize_provider(active_provider, tenant_id: tenant_id) if active_provider.present?

        requested = requested_provider_code.to_s.strip
        return ProviderConfig.normalize_provider(requested, tenant_id: tenant_id) if requested.present?

        ProviderConfig.default_provider(tenant_id: tenant_id)
      end
    end
  end
end
