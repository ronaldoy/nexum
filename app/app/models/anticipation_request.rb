class AnticipationRequest < ApplicationRecord
  STATUSES = %w[REQUESTED APPROVED FUNDED SETTLED CANCELLED REJECTED].freeze
  CHANNELS = %w[API PORTAL WEBHOOK INTERNAL].freeze

  VALID_TRANSITIONS = {
    "REQUESTED" => %w[APPROVED CANCELLED REJECTED],
    "APPROVED" => %w[FUNDED SETTLED CANCELLED],
    "FUNDED" => %w[SETTLED CANCELLED],
    "SETTLED" => [],
    "CANCELLED" => [],
    "REJECTED" => []
  }.freeze

  belongs_to :tenant
  belongs_to :receivable
  belongs_to :receivable_allocation, optional: true
  belongs_to :requester_party, class_name: "Party"
  has_many :anticipation_settlement_entries, dependent: :restrict_with_exception
  has_many :anticipation_request_events, dependent: :restrict_with_exception
  has_many :assignment_contracts, dependent: :restrict_with_exception
  has_many :escrow_payouts, dependent: :restrict_with_exception

  validates :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: { scope: :tenant_id }
  validates :requested_amount, presence: true, numericality: { greater_than: 0 }
  validates :discount_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :discount_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :net_amount, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :channel, presence: true, inclusion: { in: CHANNELS }

  validate :discount_breakdown_must_match_requested_amount

  def transition_status!(new_status, settled_at: nil, funded_at: nil, metadata: nil)
    current_status = status

    allowed = VALID_TRANSITIONS.fetch(current_status, [])
    unless allowed.include?(new_status)
      raise ActiveRecord::RecordInvalid.new(self), "Invalid status transition from #{current_status} to #{new_status}"
    end

    self.class.transaction do
      connection = ActiveRecord::Base.connection
      connection.execute("SELECT set_config('app.allow_anticipation_status_transition', 'true', true)")
      begin
        attrs = { status: new_status }
        attrs[:settled_at] = settled_at if settled_at.present?
        attrs[:funded_at] = funded_at if funded_at.present?
        if metadata.present?
          current_metadata = self.metadata || {}
          current_metadata = current_metadata.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
          attrs[:metadata] = current_metadata.merge(metadata.each_with_object({}) { |(k, v), h| h[k.to_s] = v })
        end

        update!(**attrs)
      ensure
        connection.execute("SELECT set_config('app.allow_anticipation_status_transition', 'false', true)")
      end

      record_status_event!(status_before: current_status, status_after: new_status)

      reload
    end
  end

  private

  def discount_breakdown_must_match_requested_amount
    return if requested_amount.blank? || discount_rate.blank? || discount_amount.blank? || net_amount.blank?

    expected_discount = FinancialRounding.money(requested_amount.to_d * discount_rate.to_d)
    expected_net = FinancialRounding.money(requested_amount.to_d - expected_discount)

    if discount_amount.to_d != expected_discount
      errors.add(:discount_amount, "must match requested_amount * discount_rate after rounding")
    end

    if net_amount.to_d != expected_net
      errors.add(:net_amount, "must match requested_amount - discount_amount after rounding")
    end
  end

  def record_status_event!(status_before:, status_after:)
    occurred_at = Time.current
    actor_party_id = Current.user&.party_id
    actor_role = Current.role.presence || "system"

    previous = anticipation_request_events
      .order(sequence: :desc)
      .limit(1)
      .pluck(:sequence, :event_hash)
      .first

    next_sequence = previous ? previous.fetch(0) + 1 : 1
    previous_hash = previous&.fetch(1)

    payload = {
      "anticipation_request_id" => id,
      "status_before" => status_before,
      "status_after" => status_after,
      "idempotency_key" => idempotency_key
    }

    event_hash = Digest::SHA256.hexdigest(
      "#{id}:#{next_sequence}:STATUS_TRANSITION:#{previous_hash}:#{CanonicalJson.encode(payload)}"
    )

    anticipation_request_events.create!(
      tenant_id: tenant_id,
      sequence: next_sequence,
      event_type: "STATUS_TRANSITION",
      status_before: status_before,
      status_after: status_after,
      actor_party_id: actor_party_id,
      actor_role: actor_role,
      request_id: Current.request_id,
      occurred_at: occurred_at,
      prev_hash: previous_hash,
      event_hash: event_hash,
      payload: payload
    )
  end
end
