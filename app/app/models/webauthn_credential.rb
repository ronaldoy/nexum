class WebauthnCredential < ApplicationRecord
  belongs_to :tenant
  belongs_to :user

  validates :webauthn_id, :public_key, presence: true
  validates :webauthn_id, uniqueness: { scope: %i[tenant_id user_id] }
  validates :sign_count, numericality: { greater_than_or_equal_to: 0 }
  validate :tenant_matches_user

  private

  def tenant_matches_user
    return if tenant_id.blank? || user_id.blank?
    return if user&.tenant_id == tenant_id

    errors.add(:tenant_id, "must match user tenant")
  end
end
