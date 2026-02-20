# frozen_string_literal: true

module Api
  module V1
    module Receivables
      class PayloadPresenter
        def initialize(provenance_resolver:)
          @provenance_resolver = provenance_resolver
        end

        def receivable(receivable)
          {
            id: receivable.id,
            tenant_id: receivable.tenant_id,
            kind: {
              id: receivable.receivable_kind_id,
              code: receivable.receivable_kind.code,
              source_family: receivable.receivable_kind.source_family
            },
            status: receivable.status,
            contract_reference: receivable.contract_reference,
            external_reference: receivable.external_reference,
            gross_amount: decimal_as_string(receivable.gross_amount),
            currency: receivable.currency,
            performed_at: receivable.performed_at&.iso8601,
            due_at: receivable.due_at&.iso8601,
            cutoff_at: receivable.cutoff_at&.iso8601,
            provenance: @provenance_resolver.call(receivable)
          }
        end

        def event(event)
          {
            id: event.id,
            sequence: event.sequence,
            event_type: event.event_type,
            actor_party_id: event.actor_party_id,
            actor_role: event.actor_role,
            occurred_at: event.occurred_at&.iso8601,
            request_id: event.request_id,
            event_hash: event.event_hash,
            prev_hash: event.prev_hash,
            payload: event.payload
          }
        end

        def settlement(settlement)
          {
            id: settlement.id,
            receivable_id: settlement.receivable_id,
            receivable_allocation_id: settlement.receivable_allocation_id,
            payment_reference: settlement.payment_reference,
            paid_amount: decimal_as_string(settlement.paid_amount),
            cnpj_amount: decimal_as_string(settlement.cnpj_amount),
            fdic_amount: decimal_as_string(settlement.fdic_amount),
            beneficiary_amount: decimal_as_string(settlement.beneficiary_amount),
            physician_amount: decimal_as_string(settlement.physician_amount),
            fdic_balance_before: decimal_as_string(settlement.fdic_balance_before),
            fdic_balance_after: decimal_as_string(settlement.fdic_balance_after),
            paid_at: settlement.paid_at&.iso8601,
            request_id: settlement.request_id
          }
        end

        def settlement_entry(entry)
          {
            id: entry.id,
            anticipation_request_id: entry.anticipation_request_id,
            settled_amount: decimal_as_string(entry.settled_amount),
            settled_at: entry.settled_at&.iso8601
          }
        end

        def document(document)
          {
            id: document.id,
            receivable_id: document.receivable_id,
            actor_party_id: document.actor_party_id,
            document_type: document.document_type,
            signature_method: document.signature_method,
            status: document.status,
            sha256: document.sha256,
            storage_key: document.storage_key,
            signed_at: document.signed_at&.iso8601,
            metadata: document.metadata || {},
            events: document.document_events.order(occurred_at: :asc).map { |event| document_event(event) }
          }
        end

        private

        def decimal_as_string(value)
          value.to_d.to_s("F")
        end

        def document_event(event)
          {
            id: event.id,
            event_type: event.event_type,
            occurred_at: event.occurred_at&.iso8601,
            actor_party_id: event.actor_party_id,
            request_id: event.request_id,
            payload: event.payload
          }
        end
      end
    end
  end
end
