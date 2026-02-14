class ApiAccessToken < ApplicationRecord
  TOKEN_TENANT_DELIMITER = ":".freeze
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

    [record, build_raw_token(tenant_id: tenant.id, identifier: identifier, secret: secret)]
  end

  def self.authenticate(raw_token)
    tenant_id, identifier, secret = parse_raw_token(raw_token)
    return nil if tenant_id.blank? || identifier.blank? || secret.blank?

    token = where(tenant_id: tenant_id).find_by(token_identifier: identifier)
    return nil unless token&.active_now?
    return nil unless secure_compare_digest(token.token_digest, digest(secret))

    token
  end

  def self.tenant_id_from_token(raw_token)
    tenant_id, = parse_raw_token(raw_token)
    tenant_id
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

  def self.build_raw_token(tenant_id:, identifier:, secret:)
    "#{tenant_id}#{TOKEN_TENANT_DELIMITER}#{identifier}#{TOKEN_DELIMITER}#{secret}"
  end
  private_class_method :build_raw_token

  def self.parse_raw_token(raw_token)
    tenant_part, credentials_part = raw_token.to_s.split(TOKEN_TENANT_DELIMITER, 2)
    identifier, secret = credentials_part.to_s.split(TOKEN_DELIMITER, 2)
    tenant_id = normalize_tenant_id(tenant_part)

    [tenant_id, identifier&.strip, secret&.strip]
  end
  private_class_method :parse_raw_token

  def self.normalize_tenant_id(raw_tenant_id)
    value = raw_tenant_id.to_s.strip
    return nil if value.blank?
    return nil unless value.match?(/\A[0-9a-fA-F-]{36}\z/)

    value.downcase
  end
  private_class_method :normalize_tenant_id

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
