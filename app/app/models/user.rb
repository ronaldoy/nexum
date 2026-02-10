class User < ApplicationRecord
  ROLES = %w[hospital_admin supplier_user ops_admin physician_pf_user physician_pj_admin physician_pj_member integration_api].freeze

  belongs_to :tenant
  belongs_to :party, optional: true

  encrypts :email_address, deterministic: true

  has_secure_password algorithm: :argon2
  has_many :sessions, dependent: :destroy
  has_many :api_access_tokens, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: true
  validates :role, presence: true, inclusion: { in: ROLES }
end
