class EscrowPayout < ApplicationRecord
  STATUSES = %w[PENDING PROCESSING SENT FAILED].freeze
  PROVIDERS = EscrowAccount::PROVIDERS.freeze

  belongs_to :tenant
  belongs_to :anticipation_request, optional: true
  belongs_to :receivable_payment_settlement, optional: true
  belongs_to :party
  belongs_to :escrow_account
  belongs_to :escrow_payout_batch, optional: true

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true, inclusion: { in: [ "BRL" ] }
  validates :idempotency_key, presence: true, uniqueness: { scope: :tenant_id }
  validates :provider_fee_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :provider_fee_currency, inclusion: { in: [ "BRL" ] }, allow_blank: true
  validate :source_reference_must_exist

  scope :queued, -> { where(status: "PENDING") }
  scope :in_flight, -> { where(status: %w[PENDING PROCESSING]) }
  scope :confirmed, -> { where.not(confirmed_at: nil) }

  def confirmed?
    confirmed_at.present?
  end

  def source_party
    escrow_account&.party
  end

  private

  def source_reference_must_exist
    return if anticipation_request_id.present? || receivable_payment_settlement_id.present?

    errors.add(:base, "must reference anticipation_request or receivable_payment_settlement")
  end
end
