class ReceivableAllocation < ApplicationRecord
  STATUSES = %w[OPEN SETTLED CANCELLED].freeze

  belongs_to :tenant
  belongs_to :receivable
  belongs_to :allocated_party, class_name: "Party"
  belongs_to :physician_party, class_name: "Party", optional: true

  has_many :anticipation_requests, dependent: :restrict_with_exception
  has_many :receivable_payment_settlements, dependent: :restrict_with_exception

  before_validation :apply_shared_cnpj_split

  validates :sequence, presence: true
  validates :gross_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :tax_reserve_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }

  private

  def apply_shared_cnpj_split
    return if tenant_id.blank? || gross_amount.blank?

    ReceivableAllocations::CnpjSplit.new(tenant_id: tenant_id).apply!(self)
  end
end
