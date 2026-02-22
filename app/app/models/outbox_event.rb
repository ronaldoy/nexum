class OutboxEvent < ApplicationRecord
  STATUSES = %w[PENDING SENT FAILED CANCELLED].freeze
  PAYLOAD_HASH_KEY = "payload_hash".freeze
  PAYLOAD_HASH_FORMAT = /\A[0-9a-f]{64}\z/.freeze
  PAYLOAD_HASH_ROLLOUT_CUTOFF_UTC = Time.utc(2026, 2, 22, 0, 0, 0).freeze

  belongs_to :tenant
  has_many :outbox_dispatch_attempts, dependent: :restrict_with_exception

  before_validation :ensure_idempotency_payload_hash!

  validates :aggregate_type, :aggregate_id, :event_type, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :idempotency_payload_hash_must_be_valid

  after_commit :enqueue_dispatch_job!, on: :create

  def latest_dispatch_attempt
    outbox_dispatch_attempts.order(attempt_number: :desc).first
  end

  private

  def ensure_idempotency_payload_hash!
    return if idempotency_key.to_s.strip.blank?

    normalized_payload = normalize_payload(payload)
    return if normalized_payload[PAYLOAD_HASH_KEY].to_s.strip.present?

    normalized_payload[PAYLOAD_HASH_KEY] = CanonicalJson.digest(normalized_payload.except(PAYLOAD_HASH_KEY))
    self.payload = normalized_payload
  end

  def idempotency_payload_hash_must_be_valid
    return if idempotency_key.to_s.strip.blank?

    normalized_payload = normalize_payload(payload)
    payload_hash = normalized_payload[PAYLOAD_HASH_KEY].to_s

    unless payload_hash.match?(PAYLOAD_HASH_FORMAT)
      errors.add(:payload, "payload_hash must be a lowercase sha256 hex digest.")
    end
  end

  def normalize_payload(raw_payload)
    case raw_payload
    when ActionController::Parameters
      normalize_payload(raw_payload.to_unsafe_h)
    when Hash
      raw_payload.each_with_object({}) do |(key, value), output|
        output[key.to_s] = normalize_payload(value)
      end
    when Array
      raw_payload.map { |entry| normalize_payload(entry) }
    else
      raw_payload
    end
  end

  def enqueue_dispatch_job!
    Outbox::DispatchEventJob.perform_later(tenant_id: tenant_id, outbox_event_id: id)
  end
end
