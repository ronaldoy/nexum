class Session < ApplicationRecord
  DEFAULT_TTL = 12.hours

  belongs_to :tenant
  belongs_to :user

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

  private

  def tenant_matches_user
    return if tenant_id.blank? || user_id.blank?
    return if user&.tenant_id == tenant_id

    errors.add(:tenant_id, "must match user tenant")
  end
end
