class Receivable < ApplicationRecord
  include ReceivableReporting

  CURRENCY = "BRL"
  STATUSES = %w[PERFORMED ANTICIPATION_REQUESTED FUNDED SETTLED CANCELLED].freeze

  belongs_to :tenant
  belongs_to :receivable_kind
  belongs_to :debtor_party, class_name: "Party"
  belongs_to :creditor_party, class_name: "Party"
  belongs_to :beneficiary_party, class_name: "Party"

  has_many :receivable_allocations, dependent: :restrict_with_exception
  has_many :anticipation_requests, dependent: :restrict_with_exception
  has_many :receivable_events, dependent: :restrict_with_exception
  has_many :documents, dependent: :restrict_with_exception
  has_many :receivable_payment_settlements, dependent: :restrict_with_exception

  before_validation :normalize_currency

  validates :gross_amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true, inclusion: { in: [ CURRENCY ] }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :performed_at, :due_at, :cutoff_at, presence: true

  private

  def normalize_currency
    self.currency = currency.to_s.upcase if currency.present?
  end
end
