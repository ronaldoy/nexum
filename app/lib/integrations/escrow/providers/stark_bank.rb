require "integrations/escrow/providers/base"

module Integrations
  module Escrow
    module Providers
      class StarkBank < Base
        PROVIDER_CODE = "STARKBANK".freeze

        def provider_code
          PROVIDER_CODE
        end

        def open_escrow_account!(**)
          raise ValidationError.new(
            code: "starkbank_integration_not_implemented",
            message: "StarkBank escrow account opening is not implemented yet."
          )
        end

        def create_payout!(**)
          raise ValidationError.new(
            code: "starkbank_integration_not_implemented",
            message: "StarkBank payout integration is not implemented yet."
          )
        end
      end
    end
  end
end
