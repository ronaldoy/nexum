class Role < ApplicationRecord
  CODES = %w[
    hospital_admin
    supplier_user
    ops_admin
    physician_pf_user
    physician_pj_admin
    physician_pj_member
    integration_api
  ].freeze

  belongs_to :tenant

  has_many :user_roles, dependent: :restrict_with_exception
  has_many :users, through: :user_roles

  before_validation :normalize_code
  before_validation :default_name

  validates :code, presence: true, inclusion: { in: CODES }, uniqueness: { scope: :tenant_id }
  validates :name, presence: true

  private

  def normalize_code
    normalized = code.to_s.strip.downcase
    self.code = normalized.presence
  end

  def default_name
    self.name = code.to_s.humanize if name.blank? && code.present?
  end
end
