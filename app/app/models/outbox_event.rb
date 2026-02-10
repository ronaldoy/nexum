class OutboxEvent < ApplicationRecord
  STATUSES = %w[PENDING SENT FAILED CANCELLED].freeze

  belongs_to :tenant

  validates :aggregate_type, :aggregate_id, :event_type, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
end
