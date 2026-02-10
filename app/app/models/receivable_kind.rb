class ReceivableKind < ApplicationRecord
  SOURCE_FAMILIES = %w[PHYSICIAN SUPPLIER OTHER].freeze

  belongs_to :tenant, optional: true
  has_many :receivables, dependent: :restrict_with_exception

  validates :code, presence: true
  validates :name, presence: true
  validates :source_family, presence: true, inclusion: { in: SOURCE_FAMILIES }
end
