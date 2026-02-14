class AnticipationRequest < ApplicationRecord
  STATUSES = %w[REQUESTED APPROVED FUNDED SETTLED CANCELLED REJECTED].freeze
  CHANNELS = %w[API PORTAL WEBHOOK INTERNAL].freeze

  belongs_to :tenant
  belongs_to :receivable
  belongs_to :receivable_allocation, optional: true
  belongs_to :requester_party, class_name: "Party"
  has_many :anticipation_settlement_entries, dependent: :restrict_with_exception
  has_many :assignment_contracts, dependent: :restrict_with_exception

  validates :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: { scope: :tenant_id }
  validates :requested_amount, presence: true, numericality: { greater_than: 0 }
  validates :discount_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :discount_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :net_amount, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :channel, presence: true, inclusion: { in: CHANNELS }

  validate :discount_breakdown_must_match_requested_amount

  private

  def discount_breakdown_must_match_requested_amount
    return if requested_amount.blank? || discount_rate.blank? || discount_amount.blank? || net_amount.blank?

    expected_discount = FinancialRounding.money(requested_amount.to_d * discount_rate.to_d)
    expected_net = FinancialRounding.money(requested_amount.to_d - expected_discount)

    if discount_amount.to_d != expected_discount
      errors.add(:discount_amount, "must match requested_amount * discount_rate after rounding")
    end

    if net_amount.to_d != expected_net
      errors.add(:net_amount, "must match requested_amount - discount_amount after rounding")
    end
  end
end
