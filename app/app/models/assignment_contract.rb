require "digest"

class AssignmentContract < ApplicationRecord
  STATUSES = %w[DRAFT SIGNED ACTIVE SETTLED CANCELLED].freeze
  SIGNED_STATUSES = %w[SIGNED ACTIVE SETTLED].freeze
  CURRENCY = "BRL".freeze

  belongs_to :tenant
  belongs_to :receivable
  belongs_to :anticipation_request, optional: true
  belongs_to :assignor_party, class_name: "Party"
  belongs_to :assignee_party, class_name: "Party"

  before_validation :normalize_currency

  validates :contract_number, presence: true, uniqueness: { scope: :tenant_id }
  validates :idempotency_key, presence: true, uniqueness: { scope: :tenant_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :currency, presence: true, inclusion: { in: [ CURRENCY ] }
  validates :assigned_amount, presence: true, numericality: { greater_than: 0 }

  validate :signed_at_required_for_signed_statuses
  validate :cancelled_at_required_for_cancelled_status
  validate :consistent_tenant_scope

  after_create :record_created_event
  after_update :record_status_change_event, if: :saved_change_to_status?

  private

  def normalize_currency
    self.currency = currency.to_s.upcase if currency.present?
  end

  def signed_at_required_for_signed_statuses
    return unless SIGNED_STATUSES.include?(status)
    return if signed_at.present?

    errors.add(:signed_at, "must be present when status is #{status}")
  end

  def cancelled_at_required_for_cancelled_status
    return unless status == "CANCELLED"
    return if cancelled_at.present?

    errors.add(:cancelled_at, "must be present when status is CANCELLED")
  end

  def consistent_tenant_scope
    validate_association_tenant(:receivable)
    validate_association_tenant(:anticipation_request)
    validate_association_tenant(:assignor_party)
    validate_association_tenant(:assignee_party)
  end

  def validate_association_tenant(association_name)
    association_record = public_send(association_name)
    return if association_record.blank? || tenant_id.blank?
    return if association_record.tenant_id == tenant_id

    errors.add(association_name, "must belong to the same tenant")
  end

  def record_created_event
    record_receivable_event!(
      event_type: "ASSIGNMENT_CONTRACT_CREATED",
      payload: event_payload(status_before: nil, status_after: status)
    )
  end

  def record_status_change_event
    status_before, status_after = saved_change_to_status

    record_receivable_event!(
      event_type: "ASSIGNMENT_CONTRACT_STATUS_CHANGED",
      payload: event_payload(status_before:, status_after:)
    )
  end

  def event_payload(status_before:, status_after:)
    {
      "assignment_contract_id" => id,
      "contract_number" => contract_number,
      "status_before" => status_before,
      "status_after" => status_after,
      "assigned_amount" => assigned_amount.to_s("F"),
      "currency" => currency,
      "anticipation_request_id" => anticipation_request_id
    }
  end

  def record_receivable_event!(event_type:, payload:)
    return if receivable_id.blank? || tenant_id.blank?

    occurred_at = Time.current
    actor_party_id = Current.user&.party_id
    actor_role = Current.role.presence || "system"

    Receivable.transaction do
      Receivable.where(id: receivable_id).lock(true).pick(:id)

      previous = ReceivableEvent
        .where(tenant_id: tenant_id, receivable_id: receivable_id)
        .order(sequence: :desc)
        .limit(1)
        .pluck(:sequence, :event_hash)
        .first

      next_sequence = previous ? previous.fetch(0) + 1 : 1
      previous_hash = previous&.fetch(1)

      ReceivableEvent.create!(
        tenant_id: tenant_id,
        receivable_id: receivable_id,
        sequence: next_sequence,
        event_type: event_type,
        actor_party_id: actor_party_id,
        actor_role: actor_role,
        occurred_at: occurred_at,
        request_id: Current.request_id,
        prev_hash: previous_hash,
        event_hash: event_hash_for(
          receivable_id: receivable_id,
          sequence: next_sequence,
          event_type: event_type,
          previous_hash: previous_hash,
          payload: payload
        ),
        payload: payload
      )
    end
  end

  def event_hash_for(receivable_id:, sequence:, event_type:, previous_hash:, payload:)
    canonical_payload = CanonicalJson.encode(payload)
    Digest::SHA256.hexdigest("#{receivable_id}:#{sequence}:#{event_type}:#{previous_hash}:#{canonical_payload}")
  end
end
