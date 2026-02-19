require "integrations/fdic/error"

module Integrations
  module Fdic
    module ProviderRegistry
      module_function

      def fetch(provider_code:)
        normalized = ProviderConfig.normalize_provider(provider_code)

        case normalized
        when "MOCK"
          Providers::Mock.new
        when "WEBHOOK"
          Providers::Webhook.new
        else
          raise UnsupportedProviderError.new(
            code: "unsupported_fdic_provider",
            message: "Unsupported FIDC provider: #{provider_code.inspect}",
            details: { provider: provider_code }
          )
        end
      end
    end
  end
end
