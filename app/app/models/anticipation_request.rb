class AnticipationRequest < ApplicationRecord
  STATUSES = %w[REQUESTED APPROVED FUNDED SETTLED CANCELLED REJECTED].freeze
  CHANNELS = %w[API PORTAL WEBHOOK INTERNAL].freeze

  belongs_to :tenant
  belongs_to :receivable
  belongs_to :receivable_allocation, optional: true
  belongs_to :requester_party, class_name: "Party"
  has_many :anticipation_settlement_entries, dependent: :restrict_with_exception

  validates :idempotency_key, presence: true
  validates :requested_amount, presence: true, numericality: { greater_than: 0 }
  validates :discount_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :discount_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :net_amount, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :channel, presence: true, inclusion: { in: CHANNELS }
end
