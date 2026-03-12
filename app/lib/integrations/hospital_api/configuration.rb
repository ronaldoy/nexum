require "uri"

module Integrations
  module HospitalApi
    module Configuration
      DEFAULT_PAYMENT_INSTRUCTIONS_PATH = "/api/v1/receivable_payment_instructions".freeze
      DEFAULT_OPEN_TIMEOUT_SECONDS = 3
      DEFAULT_READ_TIMEOUT_SECONDS = 10

      module_function

      def configured?(tenant_id:, hospital_party_id:)
        base_url_value(tenant_id:, hospital_party_id:).present? &&
          bearer_token_value(tenant_id:, hospital_party_id:).present?
      end

      def base_url_for(tenant_id:, hospital_party_id:)
        value = base_url_value(tenant_id:, hospital_party_id:)
        if value.blank?
          raise ConfigurationError.new(
            code: "hospital_api_base_url_missing",
            message: "Hospital API base URL is missing.",
            details: { hospital_party_id: hospital_party_id }
          )
        end

        validate_base_url!(value)
      end

      def payment_instructions_path_for(tenant_id:, hospital_party_id:)
        scoped_option(
          tenant_id:,
          hospital_party_id:,
          key: :payment_instructions_path,
          env_key: "HOSPITAL_API_PAYMENT_INSTRUCTIONS_PATH"
        ).to_s.presence || DEFAULT_PAYMENT_INSTRUCTIONS_PATH
      end

      def bearer_token_for(tenant_id:, hospital_party_id:)
        value = bearer_token_value(tenant_id:, hospital_party_id:)
        return value if value.present?

        raise ConfigurationError.new(
          code: "hospital_api_bearer_token_missing",
          message: "Hospital API bearer token is missing.",
          details: { hospital_party_id: hospital_party_id }
        )
      end

      def open_timeout_seconds_for(tenant_id:, hospital_party_id:)
        value = scoped_option(
          tenant_id:,
          hospital_party_id:,
          key: :open_timeout_seconds,
          env_key: "HOSPITAL_API_OPEN_TIMEOUT_SECONDS"
        )
        Integer(value, exception: false) || DEFAULT_OPEN_TIMEOUT_SECONDS
      end

      def read_timeout_seconds_for(tenant_id:, hospital_party_id:)
        value = scoped_option(
          tenant_id:,
          hospital_party_id:,
          key: :read_timeout_seconds,
          env_key: "HOSPITAL_API_READ_TIMEOUT_SECONDS"
        )
        Integer(value, exception: false) || DEFAULT_READ_TIMEOUT_SECONDS
      end

      def tenant_slug_for(tenant_id:)
        Tenant.find_by(id: tenant_id)&.slug.to_s.strip.downcase.presence
      end

      def scoped_option(tenant_id:, hospital_party_id:, key:, env_key:)
        tenant_slug = tenant_slug_for(tenant_id:)
        hospital_key = hospital_party_id.to_s

        if tenant_slug.present? && hospital_key.present?
          hospital_specific = Rails.app.creds.option(
            :integrations,
            :hospital_api,
            :tenants,
            tenant_slug,
            :hospitals,
            hospital_key,
            key,
            default: scoped_env_value(env_key:, tenant_slug:, hospital_party_id:)
          )
          return hospital_specific unless blank_option?(hospital_specific)
        end

        if tenant_slug.present?
          tenant_default = Rails.app.creds.option(
            :integrations,
            :hospital_api,
            :tenants,
            tenant_slug,
            key,
            default: tenant_env_value(env_key:, tenant_slug:)
          )
          return tenant_default unless blank_option?(tenant_default)
        end

        Rails.app.creds.option(:integrations, :hospital_api, key, default: ENV[env_key])
      end

      def base_url_value(tenant_id:, hospital_party_id:)
        scoped_option(
          tenant_id:,
          hospital_party_id:,
          key: :base_url,
          env_key: "HOSPITAL_API_BASE_URL"
        ).to_s.strip
      end
      private_class_method :base_url_value

      def bearer_token_value(tenant_id:, hospital_party_id:)
        scoped_option(
          tenant_id:,
          hospital_party_id:,
          key: :bearer_token,
          env_key: "HOSPITAL_API_BEARER_TOKEN"
        ).to_s.strip
      end
      private_class_method :bearer_token_value

      def scoped_env_value(env_key:, tenant_slug:, hospital_party_id:)
        env_lookup("#{env_key}__#{sanitize_env_token(tenant_slug)}__#{sanitize_env_token(hospital_party_id)}")
      end
      private_class_method :scoped_env_value

      def tenant_env_value(env_key:, tenant_slug:)
        env_lookup("#{env_key}__#{sanitize_env_token(tenant_slug)}")
      end
      private_class_method :tenant_env_value

      def env_lookup(key)
        ENV[key]
      end
      private_class_method :env_lookup

      def sanitize_env_token(value)
        value.to_s.upcase.gsub(/[^A-Z0-9]+/, "_")
      end
      private_class_method :sanitize_env_token

      def validate_base_url!(value)
        uri = URI.parse(value)
        invalid_reasons = []
        invalid_reasons << "must use HTTPS" unless uri.is_a?(URI::HTTPS)
        invalid_reasons << "must include host" if uri.host.to_s.blank?
        invalid_reasons << "must not include userinfo" if uri.userinfo.present?
        invalid_reasons << "must not include query parameters" if uri.query.present?
        invalid_reasons << "must not include fragments" if uri.fragment.present?
        if invalid_reasons.any?
          raise ConfigurationError.new(
            code: "hospital_api_base_url_invalid",
            message: "Hospital API base URL is invalid.",
            details: { reason: invalid_reasons.join(", ") }
          )
        end

        value
      rescue URI::InvalidURIError => error
        raise ConfigurationError.new(
          code: "hospital_api_base_url_invalid",
          message: "Hospital API base URL is invalid.",
          details: { error_message: error.message }
        )
      end
      private_class_method :validate_base_url!

      def blank_option?(value)
        value.nil? || value == ""
      end
      private_class_method :blank_option?
    end
  end
end
