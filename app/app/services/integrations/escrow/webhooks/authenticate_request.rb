require "openssl"

module Integrations
  module Escrow
    module Webhooks
      class AuthenticateRequest
        Error = Class.new(StandardError) do
          attr_reader :code

          def initialize(code:, message:)
            @code = code
            super(message)
          end
        end

        HMAC_HEADER_CANDIDATES = {
          "QITECH" => %w[X-QITECH-Signature X-Qitech-Signature X-Webhook-Signature],
          "STARKBANK" => %w[X-STARKBANK-Signature X-Starkbank-Signature X-Webhook-Signature]
        }.freeze

        TOKEN_HEADER_CANDIDATES = {
          "QITECH" => %w[X-QITECH-Webhook-Token X-Qitech-Webhook-Token],
          "STARKBANK" => %w[X-STARKBANK-Webhook-Token X-Starkbank-Webhook-Token]
        }.freeze

        def call(provider:, request:, raw_body:)
          provider_code = normalized_provider(provider)
          secret = webhook_secret_for(provider_code)
          token = webhook_token_for(provider_code)
          return authenticate_with_signature(provider_code:, secret:, request:, raw_body:) if secret.present?
          return authenticate_with_token(provider_code:, token:, request:) if token.present?

          raise_webhook_auth_not_configured!(provider_code)
        end

        private

        def normalized_provider(provider)
          ProviderConfig.normalize_provider(provider)
        end

        def authenticate_with_signature(provider_code:, secret:, request:, raw_body:)
          signature = extract_header(request:, candidates: HMAC_HEADER_CANDIDATES.fetch(provider_code, []))
          raise Error.new(code: "webhook_signature_missing", message: "Webhook signature header is missing.") if signature.blank?

          verify_hmac_signature!(signature:, secret:, raw_body:)
          signature
        end

        def authenticate_with_token(provider_code:, token:, request:)
          provided_token = extract_bearer_token(request) || extract_header(request:, candidates: TOKEN_HEADER_CANDIDATES.fetch(provider_code, []))
          raise Error.new(code: "webhook_token_missing", message: "Webhook token is missing.") if provided_token.blank?
          raise Error.new(code: "webhook_token_invalid", message: "Webhook token is invalid.") unless secure_compare(provided_token, token)

          "bearer"
        end

        def raise_webhook_auth_not_configured!(provider_code)
          raise Error.new(
            code: "webhook_auth_not_configured",
            message: "Webhook authentication is not configured for provider #{provider_code}."
          )
        end

        def verify_hmac_signature!(signature:, secret:, raw_body:)
          provided = normalize_signature(signature)
          expected = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body.to_s)

          unless secure_compare(provided, expected)
            raise Error.new(code: "webhook_signature_invalid", message: "Webhook signature is invalid.")
          end
        end

        def normalize_signature(value)
          raw = value.to_s.strip
          if raw.include?("=")
            algorithm, digest = raw.split("=", 2)
            raw = digest if algorithm.to_s.strip.casecmp("sha256").zero?
          end

          raw.downcase
        end

        def secure_compare(left, right)
          a = left.to_s
          b = right.to_s
          return false if a.blank? || b.blank?
          return false unless a.bytesize == b.bytesize

          ActiveSupport::SecurityUtils.secure_compare(a, b)
        end

        def extract_header(request:, candidates:)
          candidates.each do |name|
            value = request.headers[name].to_s.strip
            return value if value.present?
          end

          nil
        end

        def extract_bearer_token(request)
          scheme, value = request.authorization.to_s.split(" ", 2)
          return nil unless scheme&.casecmp("Bearer")&.zero?

          value.to_s.strip.presence
        end

        def webhook_secret_for(provider)
          case provider
          when "QITECH"
            Rails.app.creds.option(:integrations, :qitech, :webhook_secret, default: ENV["QITECH_WEBHOOK_SECRET"]).to_s.strip
          when "STARKBANK"
            Rails.app.creds.option(:integrations, :starkbank, :webhook_secret, default: ENV["STARKBANK_WEBHOOK_SECRET"]).to_s.strip
          else
            ""
          end
        end

        def webhook_token_for(provider)
          case provider
          when "QITECH"
            Rails.app.creds.option(:integrations, :qitech, :webhook_token, default: ENV["QITECH_WEBHOOK_TOKEN"]).to_s.strip
          when "STARKBANK"
            Rails.app.creds.option(:integrations, :starkbank, :webhook_token, default: ENV["STARKBANK_WEBHOOK_TOKEN"]).to_s.strip
          else
            ""
          end
        end
      end
    end
  end
end
