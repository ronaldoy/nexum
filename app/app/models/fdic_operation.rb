class FdicOperation < ApplicationRecord
  PROVIDERS = %w[MOCK WEBHOOK].freeze
  OPERATION_TYPES = %w[FUNDING_REQUEST SETTLEMENT_REPORT].freeze
  STATUSES = %w[PENDING SENT FAILED].freeze

  belongs_to :tenant
  belongs_to :anticipation_request, optional: true
  belongs_to :receivable_payment_settlement, optional: true

  validates :provider, :operation_type, :status, :amount, :currency, :idempotency_key, :requested_at, presence: true
  validates :provider, inclusion: { in: PROVIDERS }
  validates :operation_type, inclusion: { in: OPERATION_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :currency, inclusion: { in: [ "BRL" ] }
  validates :amount, numericality: { greater_than: 0 }
  validates :idempotency_key, uniqueness: { scope: :tenant_id }

  validate :single_source_reference

  scope :pending, -> { where(status: "PENDING") }

  def sent?
    status == "SENT"
  end

  private

  def single_source_reference
    references = [ anticipation_request_id.present?, receivable_payment_settlement_id.present? ].count(true)
    return if references == 1

    errors.add(:base, "must reference either anticipation_request or receivable_payment_settlement")
  end
end
