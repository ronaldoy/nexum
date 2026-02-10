class KycProfile < ApplicationRecord
  STATUSES = %w[DRAFT PENDING_REVIEW NEEDS_INFORMATION APPROVED REJECTED].freeze
  RISK_LEVELS = %w[UNKNOWN LOW MEDIUM HIGH].freeze

  belongs_to :tenant
  belongs_to :party
  belongs_to :reviewer_party, class_name: "Party", optional: true

  has_many :kyc_documents, dependent: :restrict_with_exception
  has_many :kyc_events, dependent: :restrict_with_exception

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :risk_level, presence: true, inclusion: { in: RISK_LEVELS }
end
