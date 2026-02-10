class Tenant < ApplicationRecord
  has_many :parties, dependent: :restrict_with_exception
  has_many :physicians, dependent: :restrict_with_exception
  has_many :kyc_profiles, dependent: :restrict_with_exception
  has_many :kyc_documents, dependent: :restrict_with_exception
  has_many :kyc_events, dependent: :restrict_with_exception
  has_many :receivables, dependent: :restrict_with_exception
  has_many :receivable_kinds, dependent: :restrict_with_exception
  has_many :physician_cnpj_split_policies, dependent: :restrict_with_exception
  has_many :receivable_payment_settlements, dependent: :restrict_with_exception
  has_many :anticipation_settlement_entries, dependent: :restrict_with_exception
  has_many :users, dependent: :restrict_with_exception
  has_many :api_access_tokens, dependent: :restrict_with_exception

  validates :slug, presence: true, uniqueness: true
  validates :name, presence: true
end
