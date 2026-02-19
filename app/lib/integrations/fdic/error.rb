module Integrations
  module Fdic
    class Error < StandardError
      attr_reader :code, :details

      def initialize(code:, message:, details: {})
        @code = code.to_s
        @details = details || {}
        super(message)
      end
    end

    class ConfigurationError < Error; end
    class ValidationError < Error; end
    class UnsupportedProviderError < Error; end

    class RemoteError < Error
      attr_reader :http_status

      def initialize(code:, message:, http_status:, details: {})
        @http_status = http_status
        super(code: code, message: message, details: details)
      end
    end
  end
end
