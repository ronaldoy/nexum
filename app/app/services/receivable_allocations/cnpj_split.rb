module ReceivableAllocations
  class CnpjSplit
    DEFAULT_SCOPE = "SHARED_CNPJ".freeze
    DEFAULT_CNPJ_SHARE_RATE = BigDecimal("0.30000000")
    DEFAULT_PHYSICIAN_SHARE_RATE = BigDecimal("0.70000000")

    Result = Struct.new(
      :applied,
      :scope,
      :source,
      :policy_id,
      :cnpj_share_rate,
      :physician_share_rate,
      :cnpj_share_amount,
      :physician_share_amount,
      keyword_init: true
    ) do
      def applied?
        applied
      end
    end

    def initialize(tenant_id:)
      @tenant_id = tenant_id
    end

    def apply!(allocation, at: Time.current)
      split = split_for(allocation, at:)
      return split unless split.applied?

      allocation.tax_reserve_amount = split.cnpj_share_amount
      allocation.metadata = normalized_metadata(allocation.metadata).merge(
        "cnpj_split" => {
          "applied" => true,
          "scope" => split.scope,
          "source" => split.source,
          "policy_id" => split.policy_id,
          "legal_entity_party_id" => allocation.allocated_party_id,
          "cnpj_share_rate" => decimal_as_string(split.cnpj_share_rate),
          "physician_share_rate" => decimal_as_string(split.physician_share_rate),
          "cnpj_share_amount" => decimal_as_string(split.cnpj_share_amount),
          "physician_share_amount" => decimal_as_string(split.physician_share_amount),
          "applied_at" => at.utc.iso8601(6)
        }
      )
      split
    end

    def available_amount_for_anticipation(allocation, at: Time.current)
      metadata = normalized_metadata(allocation.metadata)
      applied_split = applied_split_metadata(metadata)
      return physician_share_from_applied_split(applied_split) if applied_split

      split = split_for(allocation, at:)
      return FinancialRounding.money(allocation.gross_amount.to_d) unless split.applied?

      split.physician_share_amount
    end

    private

    def split_for(allocation, at:)
      return not_applied unless shared_cnpj_allocation?(allocation)

      policy = PhysicianCnpjSplitPolicy.resolve_for(
        tenant_id: @tenant_id,
        legal_entity_party_id: allocation.allocated_party_id,
        scope: DEFAULT_SCOPE,
        at:
      )

      cnpj_share_rate, physician_share_rate = resolve_share_rates(policy)
      cnpj_share_amount, physician_share_amount = resolve_share_amounts(
        gross_amount: allocation.gross_amount.to_d,
        cnpj_share_rate: cnpj_share_rate
      )

      Result.new(
        applied: true,
        scope: DEFAULT_SCOPE,
        source: policy.present? ? "policy" : "default",
        policy_id: policy&.id,
        cnpj_share_rate: cnpj_share_rate,
        physician_share_rate: physician_share_rate,
        cnpj_share_amount: cnpj_share_amount,
        physician_share_amount: physician_share_amount
      )
    end

    def shared_cnpj_allocation?(allocation)
      return false unless valid_allocation_for_split?(allocation)

      legal_entity_party = legal_entity_party_for(allocation)
      return false if legal_entity_party.blank? || legal_entity_party.kind != "LEGAL_ENTITY_PJ"

      active_physician_count_for(legal_entity_party.id) > 1
    end

    def valid_allocation_for_split?(allocation)
      return false if allocation.blank?
      return false if allocation.tenant_id.to_s != @tenant_id.to_s
      return false if allocation.physician_party_id.blank?
      return false if allocation.gross_amount.blank?

      true
    end

    def legal_entity_party_for(allocation)
      allocation.allocated_party || load_allocated_party(allocation)
    end

    def active_physician_count_for(legal_entity_party_id)
      PhysicianLegalEntityMembership.where(
        tenant_id: @tenant_id,
        legal_entity_party_id: legal_entity_party_id,
        status: "ACTIVE"
      ).distinct.count(:physician_party_id)
    end

    def resolve_share_rates(policy)
      cnpj_share_rate = policy&.cnpj_share_rate&.to_d || DEFAULT_CNPJ_SHARE_RATE
      physician_share_rate = policy&.physician_share_rate&.to_d || DEFAULT_PHYSICIAN_SHARE_RATE
      [ cnpj_share_rate, physician_share_rate ]
    end

    def resolve_share_amounts(gross_amount:, cnpj_share_rate:)
      cnpj_share_amount = FinancialRounding.money(gross_amount * cnpj_share_rate)
      physician_share_amount = FinancialRounding.money(gross_amount - cnpj_share_amount)
      [ cnpj_share_amount, physician_share_amount ]
    end

    def applied_split_metadata(metadata)
      applied_split = metadata["cnpj_split"]
      return nil unless applied_split.is_a?(Hash)
      return nil unless applied_split["applied"] == true

      applied_split
    end

    def physician_share_from_applied_split(applied_split)
      FinancialRounding.money(BigDecimal(applied_split.fetch("physician_share_amount").to_s))
    end

    def load_allocated_party(allocation)
      Party.find_by(id: allocation.allocated_party_id, tenant_id: @tenant_id)
    end

    def normalized_metadata(value)
      hash = value.is_a?(Hash) ? value : {}
      hash.deep_stringify_keys
    end

    def decimal_as_string(value)
      value.to_d.to_s("F")
    end

    def not_applied
      Result.new(applied: false)
    end
  end
end
