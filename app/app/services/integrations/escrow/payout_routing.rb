module Integrations
  module Escrow
    class PayoutRouting
      Route = Struct.new(
        :source_party,
        :recipient_party,
        :payout_model,
        :retention_party,
        :retention_amount,
        :retention_rate,
        keyword_init: true
      ) do
        def distribution_metadata
          {
            "payout_model" => payout_model,
            "source_party_id" => source_party&.id,
            "source_party_kind" => source_party&.kind,
            "recipient_party_id" => recipient_party&.id,
            "recipient_party_kind" => recipient_party&.kind,
            "retention_party_id" => retention_party&.id,
            "retention_amount" => format("%.2f", retention_amount.to_d),
            "retention_rate" => format("%.8f", retention_rate.to_d)
          }.compact
        end
      end

      def initialize(tenant_id:)
        @tenant_id = tenant_id
      end

      def call(payload:, anticipation_request: nil, settlement: nil)
        normalized_payload = normalize_metadata(payload)
        recipient_party = resolve_recipient_party(
          payload: normalized_payload,
          anticipation_request: anticipation_request,
          settlement: settlement
        )
        source_party = resolve_source_party(
          payload: normalized_payload,
          settlement: settlement,
          recipient_party: recipient_party
        )
        retention_amount = resolve_retention_amount(
          settlement: settlement,
          source_party: source_party,
          recipient_party: recipient_party
        )

        Route.new(
          source_party: source_party,
          recipient_party: recipient_party,
          payout_model: resolve_payout_model(source_party:, recipient_party:, settlement: settlement),
          retention_party: retention_amount.positive? ? source_party : nil,
          retention_amount: retention_amount,
          retention_rate: resolve_retention_rate(settlement:, retention_amount:)
        )
      end

      private

      def resolve_source_party(payload:, settlement:, recipient_party:)
        party_id = payload["source_party_id"].to_s.presence
        party_id ||= settlement&.receivable_allocation&.allocated_party_id
        party_id ||= settlement&.receivable&.beneficiary_party_id
        party_id ||= recipient_party&.id
        return nil if party_id.blank?

        load_party!(party_id)
      end

      def resolve_recipient_party(payload:, anticipation_request:, settlement:)
        party_id = payload["recipient_party_id"].to_s.presence
        party_id ||= anticipation_request&.requester_party_id
        party_id ||= settlement&.receivable_allocation&.physician_party_id
        party_id ||= settlement&.receivable&.beneficiary_party_id
        return nil if party_id.blank?

        load_party!(party_id)
      end

      def resolve_payout_model(source_party:, recipient_party:, settlement:)
        return "ENTITY_DIRECT" if source_party.blank? || recipient_party.blank?

        if source_party.id == recipient_party.id
          return recipient_party.kind == "PHYSICIAN_PF" ? "PHYSICIAN_DIRECT" : "ENTITY_DIRECT"
        end

        if source_party.kind == "LEGAL_ENTITY_PJ" && recipient_party.kind == "PHYSICIAN_PF"
          return "LEGAL_ENTITY_RETENTION_SPLIT"
        end

        recipient_party.kind == "PHYSICIAN_PF" ? "PHYSICIAN_DIRECT" : "ENTITY_DIRECT"
      end

      def resolve_retention_amount(settlement:, source_party:, recipient_party:)
        return BigDecimal("0") if settlement.blank? || source_party.blank? || recipient_party.blank?
        return BigDecimal("0") unless source_party.kind == "LEGAL_ENTITY_PJ"
        return BigDecimal("0") if source_party.id == recipient_party.id

        settlement.cnpj_amount.to_d
      end

      def resolve_retention_rate(settlement:, retention_amount:)
        return BigDecimal("0") if settlement.blank? || retention_amount <= 0
        return BigDecimal("0") if settlement.paid_amount.to_d <= 0

        FinancialRounding.rate(retention_amount.to_d / settlement.paid_amount.to_d)
      end

      def load_party!(party_id)
        Party.where(tenant_id: @tenant_id).lock.find(party_id)
      end

      def normalize_metadata(raw_metadata)
        case raw_metadata
        when ActionController::Parameters
          normalize_metadata(raw_metadata.to_unsafe_h)
        when Hash
          raw_metadata.each_with_object({}) do |(key, value), output|
            output[key.to_s] = normalize_metadata(value)
          end
        when Array
          raw_metadata.map { |entry| normalize_metadata(entry) }
        else
          raw_metadata
        end
      end
    end
  end
end
