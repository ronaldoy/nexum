class OutboxEvent < ApplicationRecord
  STATUSES = %w[PENDING SENT FAILED CANCELLED].freeze

  belongs_to :tenant
  has_many :outbox_dispatch_attempts, dependent: :restrict_with_exception

  validates :aggregate_type, :aggregate_id, :event_type, :status, presence: true
  validates :status, inclusion: { in: STATUSES }

  after_commit :enqueue_dispatch_job!, on: :create

  def latest_dispatch_attempt
    outbox_dispatch_attempts.order(attempt_number: :desc).first
  end

  private

  def enqueue_dispatch_job!
    Outbox::DispatchEventJob.perform_later(tenant_id: tenant_id, outbox_event_id: id)
  end
end
