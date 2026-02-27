class AnticipationRiskRule < ApplicationRecord
  SCOPE_TYPES = %w[TENANT_DEFAULT PHYSICIAN_PARTY CNPJ_PARTY HOSPITAL_PARTY].freeze
  DECISIONS = %w[ALLOW REVIEW BLOCK].freeze
  PARTY_SCOPES = SCOPE_TYPES - [ "TENANT_DEFAULT" ]

  belongs_to :tenant
  belongs_to :scope_party, class_name: "Party", optional: true
  has_many :anticipation_risk_rule_events, dependent: :restrict_with_exception

  validates :scope_type, presence: true, inclusion: { in: SCOPE_TYPES }
  validates :decision, presence: true, inclusion: { in: DECISIONS }
  validates :priority, presence: true
  validates :max_open_requests_count, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :max_single_request_amount,
            :max_daily_requested_amount,
            :max_outstanding_exposure_amount,
            numericality: { greater_than: 0 },
            allow_nil: true

  validate :scope_party_presence_by_scope_type
  validate :scope_party_kind_matches_scope
  validate :scope_party_tenant_match
  validate :effective_window_valid
  validate :at_least_one_limit_present

  scope :active, -> { where(active: true) }

  def active_at?(time)
    return false unless active?
    return false if effective_from.present? && effective_from > time
    return false if effective_until.present? && effective_until < time

    true
  end

  private

  def scope_party_presence_by_scope_type
    if scope_type == "TENANT_DEFAULT"
      errors.add(:scope_party, "must be blank for tenant default scope") if scope_party_id.present?
      return
    end

    return if PARTY_SCOPES.include?(scope_type) && scope_party_id.present?

    errors.add(:scope_party, "must be present for scoped rule")
  end

  def scope_party_kind_matches_scope
    return if scope_party.blank?

    case scope_type
    when "PHYSICIAN_PARTY"
      errors.add(:scope_party, "must be a physician party") unless scope_party.kind == "PHYSICIAN_PF"
    when "HOSPITAL_PARTY"
      errors.add(:scope_party, "must be a hospital party") unless scope_party.kind == "HOSPITAL"
    when "CNPJ_PARTY"
      errors.add(:scope_party, "must have CNPJ document type") unless scope_party.document_type == "CNPJ"
    end
  end

  def scope_party_tenant_match
    return if scope_party.blank? || tenant_id.blank?
    return if scope_party.tenant_id == tenant_id

    errors.add(:scope_party, "must belong to the same tenant")
  end

  def effective_window_valid
    return if effective_from.blank? || effective_until.blank?
    return if effective_until >= effective_from

    errors.add(:effective_until, "must be greater than or equal to effective_from")
  end

  def at_least_one_limit_present
    return if max_single_request_amount.present? ||
      max_daily_requested_amount.present? ||
      max_outstanding_exposure_amount.present? ||
      max_open_requests_count.present?

    errors.add(:base, "at least one risk limit must be configured")
  end
end
