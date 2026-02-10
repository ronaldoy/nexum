class KycDocument < ApplicationRecord
  DOCUMENT_TYPES = %w[CPF CNPJ RG CNH PASSPORT PROOF_OF_ADDRESS SELFIE CONTRACT OTHER].freeze
  STATUSES = %w[SUBMITTED VERIFIED REJECTED EXPIRED].freeze
  KEY_DOCUMENT_TYPES = %w[CPF CNPJ].freeze
  NON_KEY_IDENTITY_DOCUMENT_TYPES = %w[RG CNH PASSPORT].freeze

  belongs_to :tenant
  belongs_to :kyc_profile
  belongs_to :party

  encrypts :document_number

  before_validation :normalize_attributes

  validates :document_type, presence: true, inclusion: { in: DOCUMENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :issuing_state, inclusion: { in: BrazilianStates::ABBREVIATIONS }, allow_nil: true
  validates :storage_key, presence: true
  validates :sha256, presence: true

  validate :key_document_type_constraints
  validate :issuing_state_requires_br_country
  validate :kyc_profile_and_party_consistency

  private

  def normalize_attributes
    self.document_type = document_type.to_s.upcase.presence
    self.status = status.to_s.upcase.presence
    self.issuing_country = issuing_country.to_s.upcase.presence
    self.issuing_state = issuing_state.to_s.upcase.presence
  end

  def key_document_type_constraints
    return if document_type.blank?

    if is_key_document && !KEY_DOCUMENT_TYPES.include?(document_type)
      errors.add(:document_type, "can be key only for CPF or CNPJ")
    end

    if NON_KEY_IDENTITY_DOCUMENT_TYPES.include?(document_type) && is_key_document
      errors.add(:is_key_document, "must be false for RG, CNH or PASSPORT")
    end
  end

  def issuing_state_requires_br_country
    return if issuing_state.blank?
    return if issuing_country == "BR"

    errors.add(:issuing_state, "is only supported for issuing_country BR")
  end

  def kyc_profile_and_party_consistency
    return if kyc_profile.blank? || party.blank?

    if kyc_profile.party_id != party_id
      errors.add(:party_id, "must match the KYC profile party")
    end

    return if tenant_id.blank?

    if kyc_profile.tenant_id != tenant_id || party.tenant_id != tenant_id
      errors.add(:tenant_id, "must match tenant on profile and party")
    end
  end
end
