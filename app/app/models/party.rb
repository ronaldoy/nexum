class Party < ApplicationRecord
  KINDS = %w[HOSPITAL SUPPLIER PHYSICIAN_PF LEGAL_ENTITY_PJ FIDC PLATFORM].freeze
  DOCUMENT_TYPES = %w[CPF CNPJ].freeze
  CPF_DOCUMENT_TYPE = "CPF".freeze
  CNPJ_DOCUMENT_TYPE = "CNPJ".freeze
  CPF_KIND = "PHYSICIAN_PF".freeze

  belongs_to :tenant

  encrypts :document_number, deterministic: true
  encrypts :legal_name
  encrypts :display_name

  has_many :debtor_receivables, class_name: "Receivable", foreign_key: :debtor_party_id, inverse_of: :debtor_party, dependent: :restrict_with_exception
  has_many :creditor_receivables, class_name: "Receivable", foreign_key: :creditor_party_id, inverse_of: :creditor_party, dependent: :restrict_with_exception
  has_many :beneficiary_receivables, class_name: "Receivable", foreign_key: :beneficiary_party_id, inverse_of: :beneficiary_party, dependent: :restrict_with_exception
  has_many :physician_cnpj_split_policies, foreign_key: :legal_entity_party_id, dependent: :restrict_with_exception
  has_one :kyc_profile, dependent: :restrict_with_exception
  has_many :kyc_documents, dependent: :restrict_with_exception
  has_many :kyc_events, dependent: :restrict_with_exception
  has_many :users, dependent: :restrict_with_exception
  has_many :assignment_contracts_as_assignor, class_name: "AssignmentContract", foreign_key: :assignor_party_id, dependent: :restrict_with_exception
  has_many :assignment_contracts_as_assignee, class_name: "AssignmentContract", foreign_key: :assignee_party_id, dependent: :restrict_with_exception

  before_validation :normalize_document_number
  before_validation :normalize_document_type

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :legal_name, presence: true
  validates :document_type, presence: true, inclusion: { in: DOCUMENT_TYPES }
  validates :document_number, presence: true

  validate :document_type_must_match_kind
  validate :document_number_must_match_document_type

  private

  def normalize_document_number
    normalized = document_number.to_s.gsub(/\D+/, "")
    self.document_number = normalized.presence
  end

  def normalize_document_type
    normalized = document_type.to_s.upcase
    normalized = default_document_type_for_kind if normalized.blank?
    self.document_type = normalized.presence
  end

  def default_document_type_for_kind
    return if kind.blank?

    kind == CPF_KIND ? CPF_DOCUMENT_TYPE : CNPJ_DOCUMENT_TYPE
  end

  def document_type_must_match_kind
    return if kind.blank? || document_type.blank?
    return unless KINDS.include?(kind)

    expected_document_type = kind == CPF_KIND ? CPF_DOCUMENT_TYPE : CNPJ_DOCUMENT_TYPE
    return if document_type == expected_document_type

    errors.add(:document_type, "must be #{expected_document_type} for kind #{kind}")
  end

  def document_number_must_match_document_type
    return if document_type.blank? || document_number.blank?

    if document_type == CPF_DOCUMENT_TYPE
      errors.add(:document_number, "must be a valid CPF") unless valid_cpf?(document_number)
      return
    end

    if document_type == CNPJ_DOCUMENT_TYPE
      errors.add(:document_number, "must be a valid CNPJ") unless valid_cnpj?(document_number)
    end
  end

  def valid_cpf?(digits)
    return false unless digits.match?(/\A\d{11}\z/)
    return false if repeated_digits?(digits)

    numbers = digits.chars.map(&:to_i)
    first_check = cpf_check_digit(numbers[0..8], 10)
    second_check = cpf_check_digit(numbers[0..8] + [first_check], 11)

    numbers[9] == first_check && numbers[10] == second_check
  end

  def cpf_check_digit(values, weight_start)
    sum = values.each_with_index.sum { |value, index| value * (weight_start - index) }
    remainder = sum % 11
    remainder < 2 ? 0 : 11 - remainder
  end

  def valid_cnpj?(digits)
    return false unless digits.match?(/\A\d{14}\z/)
    return false if repeated_digits?(digits)

    numbers = digits.chars.map(&:to_i)
    first_check = cnpj_check_digit(numbers[0..11], [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
    second_check = cnpj_check_digit(numbers[0..11] + [first_check], [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])

    numbers[12] == first_check && numbers[13] == second_check
  end

  def cnpj_check_digit(values, weights)
    sum = values.each_with_index.sum { |value, index| value * weights[index] }
    remainder = sum % 11
    remainder < 2 ? 0 : 11 - remainder
  end

  def repeated_digits?(digits)
    digits.chars.uniq.one?
  end
end
