module Metadata
  module ClientMetadataSanitization
    private

    def sanitize_client_metadata(raw_metadata)
      metadata = normalize_metadata(raw_metadata)
      unless metadata.is_a?(Hash)
        raise_validation_error!("invalid_metadata", "metadata must be a JSON object.")
      end

      MetadataSanitizer.sanitize(
        metadata,
        allowed_keys: allowed_client_metadata_keys
      )
    end

    def allowed_client_metadata_keys
      configured = configured_metadata_allowed_keys
      keys = Array(configured).flat_map { |value| value.to_s.split(",") }.map { |value| value.strip }.reject(&:blank?)
      keys.presence || default_client_metadata_keys
    end

    def configured_metadata_allowed_keys
      Rails.app.creds.option(
        :security,
        metadata_allowed_keys_credential_key,
        default: ENV[metadata_allowed_keys_env_var]
      )
    end

    def metadata_allowed_keys_credential_key
      raise NotImplementedError, "metadata_allowed_keys_credential_key must be implemented by the including service."
    end

    def metadata_allowed_keys_env_var
      raise NotImplementedError, "metadata_allowed_keys_env_var must be implemented by the including service."
    end

    def default_client_metadata_keys
      self.class::DEFAULT_CLIENT_METADATA_KEYS
    end
  end
end
