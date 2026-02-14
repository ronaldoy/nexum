class UserRole < ApplicationRecord
  belongs_to :tenant
  belongs_to :user
  belongs_to :role
  belongs_to :assigned_by_user, class_name: "User", optional: true

  validates :user_id, uniqueness: { scope: :tenant_id }

  validate :tenant_matches_user
  validate :tenant_matches_role
  validate :tenant_matches_assigned_by_user

  before_validation :derive_tenant_id

  private

  def derive_tenant_id
    self.tenant_id ||= user&.tenant_id || role&.tenant_id
  end

  def tenant_matches_user
    return if tenant_id.blank? || user.blank?
    return if user.tenant_id == tenant_id

    errors.add(:user, "must belong to the same tenant")
  end

  def tenant_matches_role
    return if tenant_id.blank? || role.blank?
    return if role.tenant_id == tenant_id

    errors.add(:role, "must belong to the same tenant")
  end

  def tenant_matches_assigned_by_user
    return if tenant_id.blank? || assigned_by_user.blank?
    return if assigned_by_user.tenant_id == tenant_id

    errors.add(:assigned_by_user, "must belong to the same tenant")
  end
end
