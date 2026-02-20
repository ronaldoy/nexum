class Session < ApplicationRecord
  DEFAULT_TTL = 12.hours
  DEFAULT_ADMIN_WEBAUTHN_TTL = 15.minutes

  belongs_to :tenant
  belongs_to :user
  belongs_to :user_by_uuid, class_name: "User", foreign_key: :user_uuid_id, primary_key: :uuid_id, inverse_of: :sessions_by_uuid, optional: true

  before_validation :sync_user_uuid_reference
  validate :tenant_matches_user

  def self.ttl
    configured_hours = Integer(
      Rails.app.creds.option(:security, :session_ttl_hours, default: ENV["SESSION_TTL_HOURS"]),
      exception: false
    )

    return DEFAULT_TTL if configured_hours.nil? || configured_hours <= 0

    configured_hours.hours
  end

  def expired?(at: Time.current)
    created_at <= (at - self.class.ttl)
  end

  def self.admin_webauthn_ttl
    configured_minutes = Integer(
      Rails.app.creds.option(:security, :admin_webauthn_ttl_minutes, default: ENV["ADMIN_WEBAUTHN_TTL_MINUTES"]),
      exception: false
    )

    return DEFAULT_ADMIN_WEBAUTHN_TTL if configured_minutes.nil? || configured_minutes <= 0

    configured_minutes.minutes
  end

  def admin_webauthn_verified_recently?(at: Time.current)
    return false if admin_webauthn_verified_at.blank?

    admin_webauthn_verified_at >= (at - self.class.admin_webauthn_ttl)
  end

  def mark_admin_webauthn_verified!(at: Time.current)
    update!(admin_webauthn_verified_at: at)
  end

  def effective_user
    user_by_uuid || user
  end

  private

  def sync_user_uuid_reference
    if user.present?
      self.user_uuid_id = user.uuid_id
      return
    end

    if user_uuid_id.present?
      self.user = User.find_by(uuid_id: user_uuid_id)
      return
    end

    if user_id.present?
      self.user_uuid_id = User.where(id: user_id).pick(:uuid_id)
    end
  end

  def tenant_matches_user
    return if tenant_id.blank?

    effective_user = self.effective_user
    return if effective_user.blank?
    return if effective_user.tenant_id == tenant_id

    errors.add(:tenant_id, "must match user tenant")
  end
end
