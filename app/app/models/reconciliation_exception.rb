class ReconciliationException < ApplicationRecord
  SOURCES = %w[ESCROW_WEBHOOK].freeze
  PROVIDERS = EscrowAccount::PROVIDERS.freeze
  STATUSES = %w[OPEN RESOLVED].freeze

  belongs_to :tenant
  belongs_to :resolved_by_party, class_name: "Party", optional: true

  validates :source, :provider, :external_event_id, :code, :message, :status, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :provider, inclusion: { in: PROVIDERS }
  validates :status, inclusion: { in: STATUSES }
  validates :occurrences_count, numericality: { only_integer: true, greater_than: 0 }
  validates :external_event_id, uniqueness: { scope: %i[tenant_id source provider code] }

  scope :open, -> { where(status: "OPEN") }

  def self.capture!(
    tenant_id:,
    source:,
    provider:,
    external_event_id:,
    code:,
    message:,
    payload_sha256: nil,
    payload: {},
    metadata: {},
    observed_at: Time.current
  )
    normalized_source = source.to_s.upcase
    normalized_provider = provider.to_s.upcase
    normalized_external_event_id = external_event_id.to_s.strip
    normalized_code = code.to_s.strip
    normalized_message = message.to_s.strip.truncate(500)
    normalized_payload_sha256 = payload_sha256.to_s.strip.presence
    normalized_payload = normalize_json_hash(payload)
    normalized_metadata = normalize_json_hash(metadata)

    transaction do
      existing = lock.find_by(
        tenant_id: tenant_id,
        source: normalized_source,
        provider: normalized_provider,
        external_event_id: normalized_external_event_id,
        code: normalized_code
      )

      if existing
        existing.update!(
          message: normalized_message,
          payload_sha256: normalized_payload_sha256 || existing.payload_sha256,
          payload: normalized_payload,
          metadata: existing.metadata.to_h.merge(normalized_metadata),
          status: "OPEN",
          occurrences_count: existing.occurrences_count + 1,
          last_seen_at: observed_at,
          resolved_at: nil,
          resolved_by_party_id: nil
        )
        return existing
      end

      create!(
        tenant_id: tenant_id,
        source: normalized_source,
        provider: normalized_provider,
        external_event_id: normalized_external_event_id,
        code: normalized_code,
        message: normalized_message,
        payload_sha256: normalized_payload_sha256,
        payload: normalized_payload,
        metadata: normalized_metadata,
        status: "OPEN",
        occurrences_count: 1,
        first_seen_at: observed_at,
        last_seen_at: observed_at
      )
    end
  end

  def resolve!(resolved_by_party_id:, resolved_at: Time.current)
    update!(
      status: "RESOLVED",
      resolved_by_party_id: resolved_by_party_id,
      resolved_at: resolved_at
    )
  end

  def open?
    status == "OPEN"
  end

  class << self
    private

    def normalize_json_hash(raw)
      case raw
      when ActionController::Parameters
        normalize_json_hash(raw.to_unsafe_h)
      when Hash
        raw.each_with_object({}) do |(key, value), output|
          output[key.to_s] = normalize_json_value(value)
        end
      else
        {}
      end
    end

    def normalize_json_value(raw)
      case raw
      when ActionController::Parameters
        normalize_json_hash(raw)
      when Hash
        normalize_json_hash(raw)
      when Array
        raw.map { |entry| normalize_json_value(entry) }
      else
        raw
      end
    end
  end
end
