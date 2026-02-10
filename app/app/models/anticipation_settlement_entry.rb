class AnticipationSettlementEntry < ApplicationRecord
  belongs_to :tenant
  belongs_to :receivable_payment_settlement
  belongs_to :anticipation_request

  validates :settled_amount, presence: true, numericality: { greater_than: 0 }
  validates :settled_at, presence: true
end
