class EscrowPayout < ApplicationRecord
  STATUSES = %w[PENDING SENT FAILED].freeze
  PROVIDERS = EscrowAccount::PROVIDERS.freeze

  belongs_to :tenant
  belongs_to :anticipation_request, optional: true
  belongs_to :receivable_payment_settlement, optional: true
  belongs_to :party
  belongs_to :escrow_account

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true, inclusion: { in: [ "BRL" ] }
  validates :idempotency_key, presence: true, uniqueness: { scope: :tenant_id }
  validate :source_reference_must_exist

  private

  def source_reference_must_exist
    return if anticipation_request_id.present? || receivable_payment_settlement_id.present?

    errors.add(:base, "must reference anticipation_request or receivable_payment_settlement")
  end
end
