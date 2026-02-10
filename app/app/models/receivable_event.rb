class ReceivableEvent < ApplicationRecord
  belongs_to :tenant
  belongs_to :receivable
  belongs_to :actor_party, class_name: "Party", optional: true

  validates :sequence, presence: true
  validates :event_type, presence: true
  validates :event_hash, presence: true
  validates :occurred_at, presence: true
end
