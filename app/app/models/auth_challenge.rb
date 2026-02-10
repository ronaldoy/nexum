class AuthChallenge < ApplicationRecord
  STATUSES = %w[PENDING VERIFIED EXPIRED CANCELLED].freeze
  DELIVERY_CHANNELS = %w[EMAIL WHATSAPP].freeze

  belongs_to :tenant
  belongs_to :actor_party, class_name: "Party"

  validates :purpose, :delivery_channel, :destination_masked, :code_digest, :status, :expires_at, :target_type, :target_id, presence: true
  validates :delivery_channel, inclusion: { in: DELIVERY_CHANNELS }
  validates :status, inclusion: { in: STATUSES }
end
