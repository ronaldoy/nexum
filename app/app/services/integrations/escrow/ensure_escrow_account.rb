module Integrations
  module Escrow
    class EnsureEscrowAccount
      def call(tenant_id:, party:, provider:, idempotency_key:, metadata:)
        account = EscrowAccount.lock.find_by(
          tenant_id: tenant_id,
          party_id: party.id,
          provider: provider.provider_code
        )

        return account if active_escrow_account?(account)

        metadata_seed = provider.account_from_party_metadata(party: party)
        if metadata_seed.present?
          account = upsert_account_from_seed!(
            account: account,
            tenant_id: tenant_id,
            party: party,
            provider_code: provider.provider_code,
            seed: metadata_seed
          )
          return account if active_escrow_account?(account)
        end

        provision_result = provider.open_escrow_account!(
          tenant_id: tenant_id,
          party: party,
          idempotency_key: idempotency_key,
          metadata: metadata
        )

        account ||= EscrowAccount.new(
          tenant_id: tenant_id,
          party_id: party.id,
          provider: provider.provider_code,
          account_type: "ESCROW"
        )

        account.status = provision_result.status.to_s.upcase
        account.provider_account_id = provision_result.provider_account_id
        account.provider_request_id = provision_result.provider_request_id
        account.last_synced_at = Time.current
        account.metadata = merge_metadata(account.metadata, provision_result.metadata)
        account.save!

        unless active_escrow_account?(account)
          raise ValidationError.new(
            code: "escrow_account_not_active",
            message: "Escrow account is not active yet.",
            details: {
              party_id: party.id,
              provider: provider.provider_code,
              status: account.status,
              provider_request_id: account.provider_request_id
            }
          )
        end

        account
      rescue ActiveRecord::RecordNotUnique
        EscrowAccount.find_by!(tenant_id: tenant_id, party_id: party.id, provider: provider.provider_code)
      end

      private

      def upsert_account_from_seed!(account:, tenant_id:, party:, provider_code:, seed:)
        account ||= EscrowAccount.new(
          tenant_id: tenant_id,
          party_id: party.id,
          provider: provider_code,
          account_type: "ESCROW"
        )

        account.status = seed.fetch(:status, "ACTIVE").to_s.upcase
        account.provider_account_id = seed[:provider_account_id]
        account.provider_request_id = seed[:provider_request_id]
        account.last_synced_at = Time.current
        account.metadata = merge_metadata(account.metadata, seed[:metadata])
        account.save!
        account
      end

      def active_escrow_account?(account)
        account.present? && account.status == "ACTIVE" && account.provider_account_id.present?
      end

      def merge_metadata(existing, incoming)
        normalize_metadata(existing).merge(normalize_metadata(incoming))
      end

      def normalize_metadata(raw_metadata)
        case raw_metadata
        when ActionController::Parameters
          normalize_metadata(raw_metadata.to_unsafe_h)
        when Hash
          raw_metadata.each_with_object({}) do |(key, value), output|
            output[key.to_s] = normalize_metadata(value)
          end
        when Array
          raw_metadata.map { |entry| normalize_metadata(entry) }
        else
          raw_metadata
        end
      end
    end
  end
end
