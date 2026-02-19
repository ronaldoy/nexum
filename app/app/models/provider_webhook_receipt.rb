class ProviderWebhookReceipt < ApplicationRecord
  PROVIDERS = EscrowAccount::PROVIDERS.freeze
  STATUSES = %w[PROCESSED IGNORED FAILED].freeze

  belongs_to :tenant

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :provider_event_id, :payload_sha256, :status, :processed_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :provider_event_id, uniqueness: { scope: %i[tenant_id provider] }
end
