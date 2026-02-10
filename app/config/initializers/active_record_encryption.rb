require "base64"

Rails.application.configure do
  encryption_credentials = Rails.app.creds.option(:active_record_encryption, default: {})
  encryption_credentials = encryption_credentials.to_h.deep_symbolize_keys

  primary_key = encryption_credentials[:primary_key].to_s
  deterministic_key = encryption_credentials[:deterministic_key].to_s
  key_derivation_salt = encryption_credentials[:key_derivation_salt].to_s

  if [ primary_key, deterministic_key, key_derivation_salt ].any?(&:blank?)
    if Rails.env.production?
      raise "Missing active_record_encryption keys in Rails credentials."
    end

    # Deterministic dev/test fallback to avoid local bootstrap issues.
    fallback_secret = Rails.application.secret_key_base.to_s
    key_generator = ActiveSupport::KeyGenerator.new(
      fallback_secret,
      hash_digest_class: OpenSSL::Digest::SHA256
    )

    primary_key = Base64.strict_encode64(
      key_generator.generate_key("active_record_encryption.primary_key", 32)
    )
    deterministic_key = Base64.strict_encode64(
      key_generator.generate_key("active_record_encryption.deterministic_key", 32)
    )
    key_derivation_salt = Base64.strict_encode64(
      key_generator.generate_key("active_record_encryption.key_derivation_salt", 32)
    )
  end

  config.active_record.encryption.primary_key = primary_key
  config.active_record.encryption.deterministic_key = deterministic_key
  config.active_record.encryption.key_derivation_salt = key_derivation_salt
  config.active_record.encryption.hash_digest_class = OpenSSL::Digest::SHA256
  config.active_record.encryption.store_key_references = true
  config.active_record.encryption.support_unencrypted_data = true
  config.active_record.encryption.extend_queries = true
end
