require "integrations/fdic/error"

module Integrations
  module Fdic
    module Providers
      class Base
        def provider_code
          raise NotImplementedError, "provider_code must be implemented"
        end

        def request_funding!(tenant_id:, anticipation_request:, payload:, idempotency_key:)
          raise NotImplementedError, "request_funding! must be implemented"
        end

        def report_settlement!(tenant_id:, settlement:, payload:, idempotency_key:)
          raise NotImplementedError, "report_settlement! must be implemented"
        end
      end
    end
  end
end
