class WebauthnCredential < ApplicationRecord
  belongs_to :tenant
  belongs_to :user, foreign_key: :user_uuid_id, primary_key: :uuid_id, inverse_of: :webauthn_credentials

  validates :webauthn_id, :public_key, presence: true
  validates :webauthn_id, uniqueness: { scope: %i[tenant_id user_uuid_id] }
  validates :sign_count, numericality: { greater_than_or_equal_to: 0 }
  validate :tenant_matches_user

  private

  def tenant_matches_user
    return if tenant_id.blank? || user_uuid_id.blank?
    return if user&.tenant_id == tenant_id

    errors.add(:tenant_id, "must match user tenant")
  end
end
