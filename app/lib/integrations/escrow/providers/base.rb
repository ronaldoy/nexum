require "integrations/escrow/error"

module Integrations
  module Escrow
    module Providers
      class Base
        def provider_code
          raise NotImplementedError, "provider_code must be implemented"
        end

        def account_from_party_metadata(party:)
          nil
        end

        def open_escrow_account!(tenant_id:, party:, idempotency_key:, metadata:)
          raise NotImplementedError, "open_escrow_account! must be implemented"
        end

        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          raise NotImplementedError, "create_payout! must be implemented"
        end
      end
    end
  end
end
