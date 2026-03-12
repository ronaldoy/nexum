require "openssl"
require "integrations/escrow/providers/stark_bank_configuration"
require "starkbank"

module Integrations
  module Escrow
    module Webhooks
      class AuthenticateRequest
        SAFE_ENV_TENANT_SLUG_PATTERN = Tenant::SLUG_FORMAT
        Error = Class.new(StandardError) do
          attr_reader :code

          def initialize(code:, message:)
            @code = code
            super(message)
          end
        end

        Result = Struct.new(:signature, :event, keyword_init: true)

        HMAC_HEADER_CANDIDATES = {
          "QITECH" => %w[X-QITECH-Signature X-Qitech-Signature X-Webhook-Signature],
          "STARKBANK" => %w[Digital-Signature]
        }.freeze

        TOKEN_HEADER_CANDIDATES = {
          "QITECH" => %w[X-QITECH-Webhook-Token X-Qitech-Webhook-Token],
          "STARKBANK" => %w[X-STARKBANK-Webhook-Token X-Starkbank-Webhook-Token]
        }.freeze
        WEBHOOK_PROVIDER_CONFIG = {
          "QITECH" => {
            credentials_key: :qitech,
            secret_env: "QITECH_WEBHOOK_SECRET",
            token_env: "QITECH_WEBHOOK_TOKEN",
            token_auth_flag_env: "QITECH_WEBHOOK_ALLOW_INSECURE_TOKEN_AUTH"
          },
          "STARKBANK" => {
            credentials_key: :starkbank,
            secret_env: "STARKBANK_WEBHOOK_SECRET",
            token_env: "STARKBANK_WEBHOOK_TOKEN",
            token_auth_flag_env: "STARKBANK_WEBHOOK_ALLOW_INSECURE_TOKEN_AUTH"
          }
        }.freeze

        def call(provider:, request:, raw_body:, tenant_slug: nil, tenant_id: nil)
          provider_code = normalized_provider(provider, tenant_slug:, tenant_id:)
          return authenticate_starkbank(provider_code:, request:, raw_body:, tenant_slug:, tenant_id:) if provider_code == "STARKBANK"

          normalized_tenant_slug = normalize_tenant_slug(tenant_slug, tenant_id)
          secret = webhook_secret_for(provider_code, tenant_slug: normalized_tenant_slug)
          token = webhook_token_for(provider_code, tenant_slug: normalized_tenant_slug)
          return authenticate_with_signature(provider_code:, secret:, request:, raw_body:) if secret.present?
          return authenticate_with_token(provider_code:, token:, request:) if token_auth_enabled?(provider_code, tenant_slug: normalized_tenant_slug, token: token)
          return raise_insecure_token_auth_disabled!(provider_code) if token.present?

          raise_webhook_auth_not_configured!(provider_code)
        end

        private

        def normalized_provider(provider, tenant_slug:, tenant_id:)
          ProviderConfig.normalize_provider(provider, tenant_id:, tenant_slug:)
        end

        def authenticate_with_signature(provider_code:, secret:, request:, raw_body:)
          signature = extract_header(request:, candidates: hmac_header_candidates(provider_code))
          raise Error.new(code: "webhook_signature_missing", message: "Webhook signature header is missing.") if signature.blank?

          verify_hmac_signature!(signature:, secret:, raw_body:)
          Result.new(signature: signature)
        end

        def authenticate_with_token(provider_code:, token:, request:)
          provided_token = extract_bearer_token(request) || extract_header(request:, candidates: token_header_candidates(provider_code))
          raise Error.new(code: "webhook_token_missing", message: "Webhook token is missing.") if provided_token.blank?
          raise Error.new(code: "webhook_token_invalid", message: "Webhook token is invalid.") unless secure_compare(provided_token, token)

          Result.new(signature: "bearer")
        end

        def authenticate_starkbank(provider_code:, request:, raw_body:, tenant_slug:, tenant_id:)
          signature = extract_header(request:, candidates: hmac_header_candidates(provider_code))
          raise Error.new(code: "webhook_signature_missing", message: "Webhook signature header is missing.") if signature.blank?

          normalized_tenant_slug = normalize_tenant_slug(tenant_slug, tenant_id)
          user = Providers::StarkBankConfiguration.organization_user(tenant_slug: normalized_tenant_slug, workspace_id: nil)
          event = ::StarkBank::Event.parse(content: raw_body, signature: signature, user: user)

          Result.new(signature: signature, event: event)
        rescue ::StarkCore::Error::InvalidSignatureError
          raise Error.new(code: "webhook_signature_invalid", message: "Webhook signature is invalid.")
        end

        def raise_webhook_auth_not_configured!(provider_code)
          raise Error.new(
            code: "webhook_auth_not_configured",
            message: "Webhook authentication is not configured for provider #{provider_code}."
          )
        end

        def raise_insecure_token_auth_disabled!(provider_code)
          raise Error.new(
            code: "webhook_insecure_token_auth_disabled",
            message: "Insecure webhook token authentication is disabled for provider #{provider_code}."
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

        def hmac_header_candidates(provider)
          HMAC_HEADER_CANDIDATES.fetch(provider, [])
        end

        def token_header_candidates(provider)
          TOKEN_HEADER_CANDIDATES.fetch(provider, [])
        end

        def webhook_secret_for(provider, tenant_slug:)
          webhook_config_value(
            provider: provider,
            tenant_slug: tenant_slug,
            credential_name: :webhook_secret,
            env_key_name: :secret_env
          )
        end

        def webhook_token_for(provider, tenant_slug:)
          webhook_config_value(
            provider: provider,
            tenant_slug: tenant_slug,
            credential_name: :webhook_token,
            env_key_name: :token_env
          )
        end

        def token_auth_enabled?(provider, tenant_slug:, token:)
          return false if token.blank? || tenant_slug.blank?

          provider_config = WEBHOOK_PROVIDER_CONFIG[provider]
          return false if provider_config.blank?

          env_key = tenant_scoped_env_key(
            base_key: provider_config.fetch(:token_auth_flag_env),
            tenant_slug: tenant_slug
          )
          credentials_key = provider_config.fetch(:credentials_key)
          configured = Rails.app.creds.option(
            :integrations,
            credentials_key,
            :webhooks,
            :tenants,
            tenant_slug,
            :allow_insecure_token_auth,
            default: ENV[env_key]
          )

          ActiveModel::Type::Boolean.new.cast(configured)
        end

        def webhook_config_value(provider:, tenant_slug:, credential_name:, env_key_name:)
          provider_config = WEBHOOK_PROVIDER_CONFIG[provider]
          return "" if provider_config.blank?
          return "" if tenant_slug.blank?

          credentials_key = provider_config.fetch(:credentials_key)
          Rails.app.creds.option(
            :integrations,
            credentials_key,
            :webhooks,
            :tenants,
            tenant_slug,
            credential_name,
            default: tenant_scoped_env_value(
              base_key: provider_config.fetch(env_key_name),
              tenant_slug: tenant_slug
            )
          ).to_s.strip
        end

        def normalize_tenant_slug(tenant_slug, tenant_id)
          normalized = tenant_slug.to_s.strip.downcase
          return normalized if normalized.present?
          return nil if tenant_id.blank?

          Tenant.unscoped.where(id: tenant_id).pick(:slug).to_s.strip.downcase.presence
        end

        def tenant_scoped_env_key(base_key:, tenant_slug:)
          normalized_slug = tenant_slug.to_s.upcase.gsub(/[^A-Z0-9]+/, "_")
          "#{base_key}__#{normalized_slug}"
        end

        def tenant_scoped_env_value(base_key:, tenant_slug:)
          return nil unless SAFE_ENV_TENANT_SLUG_PATTERN.match?(tenant_slug.to_s)

          ENV[tenant_scoped_env_key(base_key:, tenant_slug: tenant_slug)]
        end
      end
    end
  end
end
