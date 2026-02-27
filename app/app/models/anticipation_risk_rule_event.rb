class AnticipationRiskRuleEvent < ApplicationRecord
  EVENT_TYPES = %w[RULE_CREATED RULE_UPDATED RULE_ACTIVATED RULE_DEACTIVATED].freeze

  belongs_to :tenant
  belongs_to :anticipation_risk_rule
  belongs_to :actor_party, class_name: "Party", optional: true

  validates :sequence, presence: true
  validates :sequence, uniqueness: { scope: %i[tenant_id anticipation_risk_rule_id] }
  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :occurred_at, presence: true
  validates :event_hash, presence: true, uniqueness: true
end
