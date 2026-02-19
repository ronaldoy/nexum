class ReceivablePaymentSettlement < ApplicationRecord
  belongs_to :tenant
  belongs_to :receivable
  belongs_to :receivable_allocation, optional: true

  has_many :anticipation_settlement_entries, dependent: :restrict_with_exception
  has_many :escrow_payouts, dependent: :restrict_with_exception
  has_many :fdic_operations, dependent: :restrict_with_exception

  validates :paid_amount, presence: true, numericality: { greater_than: 0 }
  validates :cnpj_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :fdic_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :beneficiary_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :fdic_balance_before, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :fdic_balance_after, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :paid_at, presence: true
  validates :payment_reference, presence: true
  validates :idempotency_key, presence: true, uniqueness: { scope: :tenant_id }

  validate :split_must_match_paid_amount
  validate :fdic_balance_flow_must_be_valid

  def physician_amount
    beneficiary_amount
  end

  private

  def split_must_match_paid_amount
    return if paid_amount.blank? || cnpj_amount.blank? || fdic_amount.blank? || beneficiary_amount.blank?

    split_total = cnpj_amount.to_d + fdic_amount.to_d + beneficiary_amount.to_d
    return if split_total == paid_amount.to_d

    errors.add(:base, "cnpj_amount + fdic_amount + beneficiary_amount must equal paid_amount")
  end

  def fdic_balance_flow_must_be_valid
    return if fdic_balance_before.blank? || fdic_balance_after.blank?
    return if fdic_balance_before.to_d >= fdic_balance_after.to_d

    errors.add(:fdic_balance_after, "must be less than or equal to fdic_balance_before")
  end
end
