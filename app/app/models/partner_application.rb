class PartnerApplication < ApplicationRecord
  PARTNER_APP_CREATED_ACTION = "PARTNER_APPLICATION_CREATED".freeze
  PARTNER_APP_SECRET_ROTATED_ACTION = "PARTNER_APPLICATION_SECRET_ROTATED".freeze
  PARTNER_APP_DEACTIVATED_ACTION = "PARTNER_APPLICATION_DEACTIVATED".freeze
  PARTNER_APP_TOKEN_ISSUED_ACTION = "PARTNER_APPLICATION_TOKEN_ISSUED".freeze
  ISSUED_TOKEN_NAME_PREFIX = "partner_app".freeze
  DEFAULT_TOKEN_TTL_MINUTES = 15
  ALLOWED_SCOPES = %w[
    anticipation_requests:challenge
    anticipation_requests:confirm
    anticipation_requests:write
    kyc:read
    kyc:write
    physicians:read
    physicians:write
    receivables:documents:write
    receivables:history
    receivables:read
    receivables:settle
    receivables:write
  ].freeze

  belongs_to :tenant
  belongs_to :created_by_user, class_name: "User", foreign_key: :created_by_user_uuid_id, primary_key: :uuid_id, optional: true

  validates :name, :client_id, :client_secret_digest, presence: true
  validates :scopes, presence: true
  validates :client_id, uniqueness: true
  validates :token_ttl_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 5, less_than_or_equal_to: 60 }
  validate :scopes_must_be_known

  before_validation :normalize_scopes
  before_validation :normalize_allowed_origins

  scope :active, -> { where(active: true) }

  class AuthenticationError < StandardError; end
  class ScopeError < StandardError; end

  def self.issue!(tenant:, name:, scopes:, token_ttl_minutes: DEFAULT_TOKEN_TTL_MINUTES, allowed_origins: [], metadata: {}, created_by_user: nil, audit_context: {})
    client_id = SecureRandom.uuid
    client_secret = SecureRandom.hex(32)

    application = nil
    transaction do
      application = create!(
        tenant: tenant,
        created_by_user: created_by_user,
        name: name,
        client_id: client_id,
        client_secret_digest: digest(client_secret),
        scopes: normalize_scope_values(scopes),
        token_ttl_minutes: token_ttl_minutes,
        allowed_origins: normalize_allowed_origin_values(allowed_origins),
        active: true,
        rotated_at: Time.current,
        metadata: normalize_metadata(metadata)
      )
      application.send(
        :log_lifecycle_action!,
        action_type: PARTNER_APP_CREATED_ACTION,
        success: true,
        audit_context: audit_context
      )
    end

    [ application, client_secret ]
  end

  def self.digest(secret)
    OpenSSL::Digest::SHA256.hexdigest(secret.to_s)
  end

  def self.normalize_scope_values(scopes)
    Array(scopes).map(&:to_s).map(&:strip).reject(&:blank?).uniq.sort
  end

  def self.normalize_allowed_origin_values(origins)
    Array(origins).map(&:to_s).map(&:strip).reject(&:blank?).uniq.sort
  end

  def self.secure_compare_digest(left, right)
    return false if left.blank? || right.blank?
    return false unless left.bytesize == right.bytesize

    ActiveSupport::SecurityUtils.secure_compare(left, right)
  end

  def self.normalize_metadata(raw)
    case raw
    when ActionController::Parameters
      normalize_metadata(raw.to_unsafe_h)
    when Hash
      raw.each_with_object({}) do |(key, value), output|
        output[key.to_s] = normalize_metadata(value)
      end
    when Array
      raw.map { |entry| normalize_metadata(entry) }
    else
      raw
    end
  end

  def authenticate_secret!(raw_secret)
    unless self.class.secure_compare_digest(client_secret_digest, self.class.digest(raw_secret))
      raise AuthenticationError, "client_secret is invalid."
    end

    raise AuthenticationError, "partner application is inactive." unless active?
  end

  def rotate_secret!(audit_context: {})
    new_secret = SecureRandom.hex(32)

    transaction do
      update!(
        client_secret_digest: self.class.digest(new_secret),
        rotated_at: Time.current
      )
      revoked_count = revoke_issued_tokens!(audit_context: audit_context, reason: "secret_rotated")
      log_lifecycle_action!(
        action_type: PARTNER_APP_SECRET_ROTATED_ACTION,
        success: true,
        audit_context: merge_audit_context_metadata(audit_context, "revoked_token_count" => revoked_count)
      )
    end

    new_secret
  end

  def deactivate!(audit_context: {})
    transaction do
      revoked_count = revoke_issued_tokens!(audit_context: audit_context, reason: "deactivated")
      update!(active: false)
      log_lifecycle_action!(
        action_type: PARTNER_APP_DEACTIVATED_ACTION,
        success: true,
        audit_context: merge_audit_context_metadata(audit_context, "revoked_token_count" => revoked_count)
      )
    end
  end

  def issue_access_token!(requested_scopes: nil, audit_context: {})
    scopes_to_issue = resolve_scopes_for_token!(requested_scopes)
    expires_at = Time.current + token_ttl_minutes.minutes

    issued = nil
    transaction do
      token, raw_token = ApiAccessToken.issue!(
        tenant: tenant,
        user: nil,
        name: issued_token_name,
        scopes: scopes_to_issue,
        expires_at: expires_at,
        audit_context: audit_context.merge(
          metadata: normalize_hash_metadata(audit_context[:metadata]).merge(
            "partner_application_id" => id,
            "partner_application_name" => name,
            "partner_application_client_id" => client_id
          )
        )
      )

      update!(last_used_at: Time.current)
      log_lifecycle_action!(
        action_type: PARTNER_APP_TOKEN_ISSUED_ACTION,
        success: true,
        audit_context: audit_context.merge(
          metadata: normalize_hash_metadata(audit_context[:metadata]).merge(
            "api_access_token_id" => token.id,
            "scopes" => scopes_to_issue,
            "expires_at" => expires_at.utc.iso8601(6)
          )
        )
      )

      issued = {
        token: token,
        raw_token: raw_token,
        expires_at: expires_at,
        scopes: scopes_to_issue
      }
    end

    issued
  end

  def issued_token_name
    "#{ISSUED_TOKEN_NAME_PREFIX}:#{id}:#{client_id}"
  end

  private

  def normalize_scopes
    self.scopes = self.class.normalize_scope_values(scopes)
  end

  def normalize_allowed_origins
    self.allowed_origins = self.class.normalize_allowed_origin_values(allowed_origins)
  end

  def resolve_scopes_for_token!(requested_scopes)
    requested = self.class.normalize_scope_values(requested_scope_values(requested_scopes))
    return scopes if requested.empty?

    unknown = requested - scopes
    if unknown.any?
      raise ScopeError, "requested scopes are not allowed for this partner application: #{unknown.join(', ')}"
    end

    requested
  end

  def requested_scope_values(raw_scopes)
    case raw_scopes
    when Array
      raw_scopes
    else
      raw_scopes.to_s.split(/[,\s]+/)
    end
  end

  def scopes_must_be_known
    unknown = Array(scopes) - ALLOWED_SCOPES
    return if unknown.empty?

    errors.add(:scopes, "include unsupported values: #{unknown.join(', ')}")
  end

  def revoke_issued_tokens!(audit_context:, reason:)
    scope = ApiAccessToken
      .where(tenant_id: tenant_id, user_uuid_id: nil, name: issued_token_name, revoked_at: nil)
      .where("expires_at IS NULL OR expires_at > ?", Time.current)
      .lock
    metadata = normalize_hash_metadata(audit_context[:metadata]).merge(
      "partner_application_id" => id,
      "partner_application_name" => name,
      "partner_application_client_id" => client_id,
      "partner_token_revoke_reason" => reason
    )

    revoked_count = 0
    scope.find_each do |token|
      token.revoke!(
        audit_context: audit_context.merge(metadata: metadata.merge("revoked_token_id" => token.id))
      )
      revoked_count += 1
    end

    revoked_count
  end

  def merge_audit_context_metadata(audit_context, additional_metadata)
    base = audit_context.is_a?(Hash) ? audit_context.dup : {}
    base[:metadata] = normalize_hash_metadata(base[:metadata]).merge(normalize_hash_metadata(additional_metadata))
    base
  end

  def log_lifecycle_action!(action_type:, success:, audit_context:)
    metadata = normalize_hash_metadata(audit_context[:metadata]).merge(
      "partner_application_id" => id,
      "partner_application_name" => name,
      "partner_application_client_id" => client_id,
      "scopes" => Array(scopes),
      "token_ttl_minutes" => token_ttl_minutes,
      "active" => active
    )

    ActionIpLog.create!(
      tenant_id: tenant_id,
      actor_party_id: audit_context[:actor_party_id] || created_by_user&.party_id,
      action_type: action_type,
      ip_address: audit_context[:ip_address].presence || "0.0.0.0",
      user_agent: audit_context[:user_agent],
      request_id: audit_context[:request_id],
      endpoint_path: audit_context[:endpoint_path],
      http_method: audit_context[:http_method],
      channel: audit_context[:channel].presence || "ADMIN",
      target_type: "PartnerApplication",
      target_id: id,
      success: success,
      occurred_at: Time.current,
      metadata: metadata
    )
  rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => error
    Rails.logger.error(
      "partner_application_audit_log_write_error " \
      "partner_application_id=#{id} action_type=#{action_type} error_class=#{error.class.name} error_message=#{error.message}"
    )
    raise
  end

  def normalize_metadata(raw)
    self.class.normalize_metadata(raw)
  end

  def normalize_hash_metadata(raw)
    normalized = normalize_metadata(raw)
    normalized.is_a?(Hash) ? normalized : {}
  end
end
