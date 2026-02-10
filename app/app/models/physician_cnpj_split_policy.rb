class PhysicianCnpjSplitPolicy < ApplicationRecord
  SCOPES = %w[SHARED_CNPJ].freeze
  STATUSES = %w[ACTIVE INACTIVE].freeze

  belongs_to :tenant
  belongs_to :legal_entity_party, class_name: "Party"

  validates :scope, presence: true, inclusion: { in: SCOPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :cnpj_share_rate, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :physician_share_rate, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :effective_from, presence: true

  validate :legal_entity_party_must_be_pj
  validate :effective_window_must_be_valid
  validate :share_rates_must_sum_to_one

  scope :active, -> { where(status: "ACTIVE") }

  def self.resolve_for(tenant_id:, legal_entity_party_id:, scope: "SHARED_CNPJ", at: Time.current)
    where(tenant_id:, legal_entity_party_id:, scope:)
      .active
      .where("effective_from <= ?", at)
      .where("effective_until IS NULL OR effective_until >= ?", at)
      .order(effective_from: :desc)
      .first
  end

  private

  def legal_entity_party_must_be_pj
    return if legal_entity_party.blank? || legal_entity_party.kind == "LEGAL_ENTITY_PJ"

    errors.add(:legal_entity_party, "must be a LEGAL_ENTITY_PJ party")
  end

  def effective_window_must_be_valid
    return if effective_from.blank? || effective_until.blank?
    return if effective_until >= effective_from

    errors.add(:effective_until, "must be greater than or equal to effective_from")
  end

  def share_rates_must_sum_to_one
    return if cnpj_share_rate.blank? || physician_share_rate.blank?

    total = cnpj_share_rate.to_d + physician_share_rate.to_d
    return if total == BigDecimal("1")

    errors.add(:base, "cnpj_share_rate + physician_share_rate must equal 1.00000000")
  end
end
