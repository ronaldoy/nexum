require "digest"

module Integrations
  module Fdic
    module Providers
      class Mock < Base
        def provider_code
          "MOCK"
        end

        def request_funding!(tenant_id:, anticipation_request:, payload:, idempotency_key:)
          OperationResult.new(
            provider_reference: mock_reference_for(kind: "funding", idempotency_key: idempotency_key),
            status: "SENT",
            metadata: {
              "provider" => provider_code,
              "mode" => "mock",
              "kind" => "funding",
              "tenant_id" => tenant_id,
              "anticipation_request_id" => anticipation_request.id,
              "request_control_key" => idempotency_key
            }
          )
        end

        def report_settlement!(tenant_id:, settlement:, payload:, idempotency_key:)
          OperationResult.new(
            provider_reference: mock_reference_for(kind: "settlement", idempotency_key: idempotency_key),
            status: "SENT",
            metadata: {
              "provider" => provider_code,
              "mode" => "mock",
              "kind" => "settlement",
              "tenant_id" => tenant_id,
              "receivable_payment_settlement_id" => settlement.id,
              "request_control_key" => idempotency_key
            }
          )
        end

        private

        def mock_reference_for(kind:, idempotency_key:)
          digest = Digest::SHA256.hexdigest("#{kind}:#{idempotency_key}")[0, 20]
          "mock-#{kind}-#{digest}"
        end
      end
    end
  end
end
