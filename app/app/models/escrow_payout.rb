class EscrowPayout < ApplicationRecord
  STATUSES = %w[PENDING SENT FAILED].freeze
  PROVIDERS = EscrowAccount::PROVIDERS.freeze

  belongs_to :tenant
  belongs_to :anticipation_request
  belongs_to :party
  belongs_to :escrow_account

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true, inclusion: { in: [ "BRL" ] }
  validates :idempotency_key, presence: true, uniqueness: { scope: :tenant_id }
end
