class Document < ApplicationRecord
  belongs_to :tenant
  belongs_to :receivable
  belongs_to :actor_party, class_name: "Party"

  has_many :document_events, dependent: :restrict_with_exception

  validates :document_type, :signature_method, :status, :sha256, :storage_key, :signed_at, presence: true
end
