class EscrowAccount < ApplicationRecord
  PROVIDERS = %w[QITECH STARKBANK].freeze
  STATUSES = %w[PENDING ACTIVE REJECTED FAILED CLOSED].freeze
  ACCOUNT_TYPES = %w[ESCROW].freeze

  belongs_to :tenant
  belongs_to :party

  has_many :escrow_payouts, dependent: :restrict_with_exception

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :account_type, presence: true, inclusion: { in: ACCOUNT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :party_id, uniqueness: { scope: %i[tenant_id provider] }

  scope :for_provider, ->(provider) { where(provider: provider.to_s.upcase) }
  scope :active, -> { where(status: "ACTIVE") }
end
