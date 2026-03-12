require "digest"

class ReceivingAccount < ApplicationRecord
  PAYMENT_RAILS = %w[PIX].freeze
  STATUSES = %w[ACTIVE INACTIVE].freeze
  ACCOUNT_TYPES = %w[checking savings salary payment].freeze
  ISPB_FORMAT = /\A\d{8}\z/.freeze
  DOCUMENT_FORMAT = /\A\d{11}|\d{14}\z/.freeze

  belongs_to :tenant
  belongs_to :party

  encrypts :branch_code, deterministic: true
  encrypts :account_number, deterministic: true
  encrypts :holder_name
  encrypts :holder_document_number, deterministic: true

  scope :active, -> { where(status: "ACTIVE") }
  scope :primary_account, -> { where(primary: true) }

  before_validation :normalize_bank_code
  before_validation :normalize_account_type
  before_validation :normalize_encrypted_fields
  before_validation :apply_party_defaults
  before_validation :assign_account_fingerprint

  validates :payment_rail, presence: true, inclusion: { in: PAYMENT_RAILS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :account_type, presence: true, inclusion: { in: ACCOUNT_TYPES }
  validates :bank_code, presence: true, format: { with: ISPB_FORMAT }
  validates :branch_code, :account_number, :holder_name, :holder_document_number, :account_fingerprint, presence: true
  validates :account_fingerprint, uniqueness: { scope: %i[tenant_id party_id] }
  validate :holder_document_number_must_match_party
  validate :single_active_primary_account_per_party

  def masked_account_number
    value = account_number.to_s
    return "-" if value.blank?

    stripped = value.gsub(/\D+/, "")
    return value if stripped.length <= 4

    "#{('*' * [ stripped.length - 4, 0 ].max)}#{stripped[-4, 4]}"
  end

  private

  def normalize_bank_code
    self.bank_code = bank_code.to_s.gsub(/\D+/, "").presence
  end

  def normalize_account_type
    self.account_type = account_type.to_s.strip.downcase.presence
  end

  def normalize_encrypted_fields
    self.branch_code = branch_code.to_s.gsub(/[^\d-]+/, "").presence
    self.account_number = account_number.to_s.gsub(/[^\d-]+/, "").presence
    self.holder_document_number = holder_document_number.to_s.gsub(/\D+/, "").presence
    self.holder_name = holder_name.to_s.strip.presence
  end

  def apply_party_defaults
    return if party.blank?

    self.holder_name = holder_name.presence || party.legal_name.to_s.strip.presence
    self.holder_document_number = holder_document_number.presence || party.document_number.to_s.gsub(/\D+/, "").presence
  end

  def assign_account_fingerprint
    return if bank_code.blank? || branch_code.blank? || account_number.blank? || account_type.blank? || holder_document_number.blank?

    canonical = [
      bank_code,
      branch_code.to_s.gsub(/[^\d-]+/, ""),
      account_number.to_s.gsub(/[^\d-]+/, ""),
      account_type.to_s.downcase,
      holder_document_number.to_s.gsub(/\D+/, "")
    ].join(":")

    self.account_fingerprint = Digest::SHA256.hexdigest(canonical)
  end

  def holder_document_number_must_match_party
    return if party.blank? || holder_document_number.blank?

    expected = party.document_number.to_s.gsub(/\D+/, "")
    return if expected.present? && expected == holder_document_number

    errors.add(:holder_document_number, "must match the receiving party document number")
  end

  def single_active_primary_account_per_party
    return unless primary? && status == "ACTIVE" && tenant_id.present? && party_id.present?

    existing = self.class.where(tenant_id: tenant_id, party_id: party_id, primary: true, status: "ACTIVE")
    existing = existing.where.not(id: id) if persisted?
    return unless existing.exists?

    errors.add(:base, "only one active primary receiving account is allowed per party")
  end
end
