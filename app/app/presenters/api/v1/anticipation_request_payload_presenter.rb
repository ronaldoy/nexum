# frozen_string_literal: true

module Api
  module V1
    class AnticipationRequestPayloadPresenter
      def initialize(provenance_resolver:)
        @provenance_resolver = provenance_resolver
      end

      def anticipation_request(record, replayed:)
        {
          id: record.id,
          tenant_id: record.tenant_id,
          receivable_id: record.receivable_id,
          receivable_allocation_id: record.receivable_allocation_id,
          requester_party_id: record.requester_party_id,
          status: record.status,
          channel: record.channel,
          idempotency_key: record.idempotency_key,
          requested_amount: decimal_money_as_string(record.requested_amount),
          discount_rate: decimal_as_string(record.discount_rate),
          discount_amount: decimal_money_as_string(record.discount_amount),
          net_amount: decimal_money_as_string(record.net_amount),
          settlement_target_date: record.settlement_target_date&.iso8601,
          requested_at: record.requested_at&.iso8601,
          confirmed_at: record.metadata&.dig("confirmed_at"),
          confirmation_channels: Array(record.metadata&.dig("confirmation_channels")),
          receivable_provenance: @provenance_resolver.call(record.receivable),
          replayed: replayed
        }
      end

      def challenge_issue(result)
        {
          anticipation_request_id: result.anticipation_request.id,
          replayed: result.replayed?,
          challenges: result.challenges.map { |challenge| challenge_payload(challenge) }
        }
      end

      private

      def challenge_payload(challenge)
        {
          id: challenge.id,
          delivery_channel: challenge.delivery_channel,
          destination_masked: challenge.destination_masked,
          status: challenge.status,
          expires_at: challenge.expires_at&.iso8601
        }
      end

      def decimal_money_as_string(value)
        format("%.2f", value.to_d)
      end

      def decimal_as_string(value)
        value.to_d.to_s("F")
      end
    end
  end
end
