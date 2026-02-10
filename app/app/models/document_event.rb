class DocumentEvent < ApplicationRecord
  belongs_to :tenant
  belongs_to :document
  belongs_to :receivable
  belongs_to :actor_party, class_name: "Party", optional: true

  validates :event_type, :occurred_at, presence: true
end
