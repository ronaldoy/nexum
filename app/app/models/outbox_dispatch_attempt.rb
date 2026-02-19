class OutboxDispatchAttempt < ApplicationRecord
  STATUSES = %w[SENT RETRY_SCHEDULED DEAD_LETTER].freeze

  belongs_to :tenant
  belongs_to :outbox_event

  validates :attempt_number, presence: true, numericality: { greater_than: 0, only_integer: true }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :occurred_at, presence: true
end
