class AnticipationRequestEvent < ApplicationRecord
  belongs_to :tenant
  belongs_to :anticipation_request
  belongs_to :actor_party, class_name: "Party", optional: true

  validates :sequence, presence: true, uniqueness: { scope: [:tenant_id, :anticipation_request_id] }
  validates :event_type, presence: true
  validates :event_hash, presence: true
  validates :occurred_at, presence: true
end
