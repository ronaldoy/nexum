class HospitalOwnership < ApplicationRecord
  ORGANIZATION_KINDS = %w[LEGAL_ENTITY_PJ PLATFORM].freeze

  belongs_to :tenant
  belongs_to :organization_party, class_name: "Party"
  belongs_to :hospital_party, class_name: "Party"

  validates :organization_party_id, uniqueness: {
    scope: %i[tenant_id hospital_party_id],
    message: "already owns this hospital for the tenant"
  }
  validates :active, inclusion: { in: [ true, false ] }

  validate :organization_party_kind_must_be_supported
  validate :hospital_party_kind_must_be_hospital
  validate :parties_must_match_tenant

  scope :active, -> { where(active: true) }

  private

  def organization_party_kind_must_be_supported
    return if organization_party.blank?
    return if ORGANIZATION_KINDS.include?(organization_party.kind)

    errors.add(:organization_party, "must be a legal entity organization")
  end

  def hospital_party_kind_must_be_hospital
    return if hospital_party.blank?
    return if hospital_party.kind == "HOSPITAL"

    errors.add(:hospital_party, "must be a hospital party")
  end

  def parties_must_match_tenant
    return if tenant_id.blank?

    if organization_party.present? && organization_party.tenant_id != tenant_id
      errors.add(:organization_party, "must belong to the same tenant")
    end
    if hospital_party.present? && hospital_party.tenant_id != tenant_id
      errors.add(:hospital_party, "must belong to the same tenant")
    end
  end
end
