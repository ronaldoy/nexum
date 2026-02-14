class LedgerTransaction < ApplicationRecord
  belongs_to :tenant
  belongs_to :receivable, optional: true
  belongs_to :actor_party, class_name: "Party", optional: true

  validates :txn_id, presence: true
  validates :source_type, presence: true
  validates :source_id, presence: true
  validates :request_id, presence: true
  validates :payload_hash, presence: true
  validates :entry_count, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :posted_at, presence: true

  validates :txn_id, uniqueness: { scope: :tenant_id }
end
