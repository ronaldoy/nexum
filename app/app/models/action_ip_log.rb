class ActionIpLog < ApplicationRecord
  CHANNELS = %w[API PORTAL WORKER WEBHOOK ADMIN].freeze

  belongs_to :tenant
  belongs_to :actor_party, class_name: "Party", optional: true

  validates :action_type, :ip_address, :channel, :occurred_at, presence: true
  validates :channel, inclusion: { in: CHANNELS }
end
