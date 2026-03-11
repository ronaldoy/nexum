class AuthChallenge < ApplicationRecord
  STATUSES = %w[PENDING VERIFIED EXPIRED CANCELLED].freeze
  DELIVERY_CHANNELS = %w[EMAIL WHATSAPP].freeze
  CODE_DIGEST_VERSION = "hmac-sha256-v1".freeze
  CODE_ENCRYPTION_PURPOSE = "auth_challenge_code".freeze

  belongs_to :tenant
  belongs_to :actor_party, class_name: "Party"

  validates :purpose, :delivery_channel, :destination_masked, :code_digest, :status, :expires_at, :target_type, :target_id, presence: true
  validates :delivery_channel, inclusion: { in: DELIVERY_CHANNELS }
  validates :status, inclusion: { in: STATUSES }

  class << self
    def digest_code(raw_code)
      normalized_code = normalize_code(raw_code)
      return "" if normalized_code.blank?

      "#{CODE_DIGEST_VERSION}$#{OpenSSL::HMAC.hexdigest("SHA256", code_digest_secret, normalized_code)}"
    end

    def valid_code?(raw_code:, stored_digest:)
      normalized_code = normalize_code(raw_code)
      digest = stored_digest.to_s
      return false if normalized_code.blank? || digest.blank?

      expected_digest = if digest.start_with?("#{CODE_DIGEST_VERSION}$")
        digest_code(normalized_code)
      else
        Digest::SHA256.hexdigest(normalized_code)
      end

      secure_compare_digest(expected_digest, digest)
    end

    def encrypt_code(raw_code)
      normalized_code = normalize_code(raw_code)
      raise ArgumentError, "challenge code is blank" if normalized_code.blank?

      code_encryptor.encrypt_and_sign(normalized_code, purpose: CODE_ENCRYPTION_PURPOSE)
    end

    def decrypt_code(encrypted_code)
      payload = encrypted_code.to_s.strip
      return nil if payload.blank?

      code_encryptor.decrypt_and_verify(payload, purpose: CODE_ENCRYPTION_PURPOSE)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    private

    def normalize_code(raw_code)
      raw_code.to_s.strip
    end

    def code_digest_secret
      Rails.application.key_generator.generate_key("auth_challenge_code_digest", 32)
    end

    def code_encryptor
      secret = Rails.application.key_generator.generate_key(
        "auth_challenge_code_encryption",
        ActiveSupport::MessageEncryptor.key_len
      )
      ActiveSupport::MessageEncryptor.new(secret)
    end

    def secure_compare_digest(left, right)
      return false if left.blank? || right.blank?
      return false unless left.bytesize == right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
  end
end
