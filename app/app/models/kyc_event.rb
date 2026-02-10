class KycEvent < ApplicationRecord
  belongs_to :tenant
  belongs_to :kyc_profile
  belongs_to :party
  belongs_to :actor_party, class_name: "Party", optional: true

  validates :event_type, presence: true
  validates :occurred_at, presence: true
end
