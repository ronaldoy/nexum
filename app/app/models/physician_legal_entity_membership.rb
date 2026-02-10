class PhysicianLegalEntityMembership < ApplicationRecord
  MEMBERSHIP_ROLES = %w[ADMIN MEMBER].freeze
  STATUSES = %w[ACTIVE INACTIVE].freeze

  belongs_to :tenant
  belongs_to :physician_party, class_name: "Party"
  belongs_to :legal_entity_party, class_name: "Party"

  validates :membership_role, presence: true, inclusion: { in: MEMBERSHIP_ROLES }
  validates :status, presence: true, inclusion: { in: STATUSES }
end
