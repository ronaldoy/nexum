class ApiAccessToken < ApplicationRecord
  TOKEN_DELIMITER = ".".freeze

  belongs_to :tenant
  belongs_to :user, optional: true

  validates :name, :token_identifier, :token_digest, presence: true
  validates :token_identifier, uniqueness: true

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  before_validation :normalize_scopes

  def self.issue!(tenant:, name:, scopes: [], user: nil, expires_at: nil)
    secret = SecureRandom.hex(32)
    identifier = SecureRandom.uuid

    record = create!(
      tenant: tenant,
      user: user,
      name: name,
      scopes: normalize_scope_values(scopes),
      token_identifier: identifier,
      token_digest: digest(secret),
      expires_at: expires_at
    )

    [record, "#{identifier}#{TOKEN_DELIMITER}#{secret}"]
  end

  def self.authenticate(raw_token)
    identifier, secret = raw_token.to_s.split(TOKEN_DELIMITER, 2)
    return nil if identifier.blank? || secret.blank?

    token = find_by(token_identifier: identifier)
    return nil unless token&.active_now?
    return nil unless secure_compare_digest(token.token_digest, digest(secret))

    token
  end

  def self.digest(secret)
    OpenSSL::Digest::SHA256.hexdigest(secret.to_s)
  end

  def self.normalize_scope_values(scopes)
    Array(scopes).map(&:to_s).map(&:strip).reject(&:blank?).uniq.sort
  end

  def self.secure_compare_digest(left, right)
    return false if left.blank? || right.blank?
    return false unless left.bytesize == right.bytesize

    ActiveSupport::SecurityUtils.secure_compare(left, right)
  end

  def active_now?
    revoked_at.nil? && (expires_at.nil? || expires_at.future?)
  end

  def touch_last_used!
    update_columns(last_used_at: Time.current, updated_at: Time.current)
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  private

  def normalize_scopes
    self.scopes = self.class.normalize_scope_values(scopes)
  end
end
