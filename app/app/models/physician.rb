class Physician < ApplicationRecord
  belongs_to :tenant
  belongs_to :party

  encrypts :full_name
  encrypts :email, deterministic: true
  encrypts :phone

  before_validation :normalize_crm

  validates :full_name, presence: true
  validates :crm_number, format: { with: /\A\d{4,10}\z/, message: "must contain 4 to 10 digits" }, allow_nil: true
  validates :crm_state, inclusion: { in: BrazilianStates::ABBREVIATIONS }, allow_nil: true
  validates :crm_number, uniqueness: { scope: %i[tenant_id crm_state] }, allow_nil: true

  validate :crm_pair_presence

  private

  def normalize_crm
    self.crm_number = crm_number.to_s.gsub(/\D+/, "").presence
    self.crm_state = crm_state.to_s.upcase.presence
  end

  def crm_pair_presence
    return if crm_number.blank? && crm_state.blank?
    return if crm_number.present? && crm_state.present?

    errors.add(:base, "crm_number and crm_state must be provided together")
  end
end
