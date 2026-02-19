require "integrations/escrow/error"

module Integrations
  module Escrow
    module ProviderRegistry
      module_function

      def fetch(provider_code:)
        normalized = ProviderConfig.normalize_provider(provider_code)

        case normalized
        when "QITECH"
          Providers::QiTech.new
        when "STARKBANK"
          Providers::StarkBank.new
        else
          raise UnsupportedProviderError.new(
            code: "unsupported_escrow_provider",
            message: "Unsupported escrow provider: #{provider_code.inspect}",
            details: { provider: provider_code }
          )
        end
      end
    end
  end
end
