class AnticipationRiskDecision < ApplicationRecord
  STAGES = %w[CREATE CONFIRM].freeze
  DECISION_ACTIONS = %w[ALLOW REVIEW BLOCK].freeze

  belongs_to :tenant
  belongs_to :anticipation_request, optional: true
  belongs_to :receivable
  belongs_to :receivable_allocation, optional: true
  belongs_to :requester_party, class_name: "Party"
  belongs_to :scope_party, class_name: "Party", optional: true
  belongs_to :trigger_rule, class_name: "AnticipationRiskRule", optional: true

  validates :stage, presence: true, inclusion: { in: STAGES }
  validates :decision_action, presence: true, inclusion: { in: DECISION_ACTIONS }
  validates :decision_code, presence: true
  validates :requested_amount, numericality: { greater_than: 0 }
  validates :net_amount, numericality: { greater_than: 0 }
  validates :evaluated_at, presence: true

  validate :scope_party_tenant_match

  private

  def scope_party_tenant_match
    return if scope_party.blank? || tenant_id.blank?
    return if scope_party.tenant_id == tenant_id

    errors.add(:scope_party, "must belong to the same tenant")
  end
end
