class PhysicianAnticipationAuthorization < ApplicationRecord
  STATUSES = %w[ACTIVE REVOKED EXPIRED].freeze

  belongs_to :tenant
  belongs_to :legal_entity_party, class_name: "Party"
  belongs_to :granted_by_membership, class_name: "PhysicianLegalEntityMembership"
  belongs_to :beneficiary_physician_party, class_name: "Party"

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :valid_from, presence: true
end
