class EscrowPayoutBatch < ApplicationRecord
  PROVIDERS = EscrowAccount::PROVIDERS.freeze
  STATUSES = %w[OPEN CLOSED FAILED].freeze

  belongs_to :tenant

  has_many :escrow_payouts, dependent: :restrict_with_exception

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :source_provider_account_id, presence: true
  validates :risk_limit_amount, presence: true, numericality: { greater_than: 0 }
  validates :balance_snapshot_amount, :reserved_amount, :dispatched_amount, :fee_amount,
    presence: true,
    numericality: { greater_than_or_equal_to: 0 }

  scope :open_batches, -> { where(status: "OPEN") }
  scope :recent_first, -> { order(started_at: :desc, created_at: :desc) }

  def remaining_capacity
    [ risk_limit_amount.to_d - reserved_amount.to_d, 0.to_d ].max
  end

  def available_snapshot_budget
    [ balance_snapshot_amount.to_d - reserved_amount.to_d, 0.to_d ].max
  end
end
