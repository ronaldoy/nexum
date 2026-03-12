class ReceivablePaymentSettlement < ApplicationRecord
  belongs_to :tenant
  belongs_to :receivable
  belongs_to :receivable_allocation, optional: true

  has_many :anticipation_settlement_entries, dependent: :restrict_with_exception
  has_many :escrow_payouts, dependent: :restrict_with_exception
  has_many :fidc_operations, dependent: :restrict_with_exception

  validates :paid_amount, presence: true, numericality: { greater_than: 0 }
  validates :cnpj_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :fidc_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :beneficiary_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :fidc_balance_before, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :fidc_balance_after, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :paid_at, presence: true
  validates :payment_reference, presence: true
  validates :idempotency_key, presence: true, uniqueness: { scope: :tenant_id }

  validate :split_must_match_paid_amount
  validate :fidc_balance_flow_must_be_valid

  def physician_amount
    beneficiary_amount
  end

  def operational_source_party
    receivable_allocation&.allocated_party || receivable&.beneficiary_party
  end

  def payout_recipient_party
    receivable_allocation&.physician_party || receivable&.beneficiary_party
  end

  def retained_amount
    cnpj_amount.to_d
  end

  def retention_rate
    return BigDecimal("0") if paid_amount.to_d <= 0

    FinancialRounding.rate(retained_amount / paid_amount.to_d)
  end

  def payout_model
    metadata&.dig("distribution_model", "payout_model").to_s.presence || "ENTITY_DIRECT"
  end

  private

  def split_must_match_paid_amount
    return if paid_amount.blank? || cnpj_amount.blank? || fidc_amount.blank? || beneficiary_amount.blank?

    split_total = cnpj_amount.to_d + fidc_amount.to_d + beneficiary_amount.to_d
    return if split_total == paid_amount.to_d

    errors.add(:base, "cnpj_amount + fidc_amount + beneficiary_amount must equal paid_amount")
  end

  def fidc_balance_flow_must_be_valid
    return if fidc_balance_before.blank? || fidc_balance_after.blank?
    return if fidc_balance_before.to_d >= fidc_balance_after.to_d

    errors.add(:fidc_balance_after, "must be less than or equal to fidc_balance_before")
  end
end
