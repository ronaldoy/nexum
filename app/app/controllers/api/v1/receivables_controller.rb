module Api
  module V1
    class ReceivablesController < Api::BaseController
      require_api_scopes(
        index: "receivables:read",
        show: "receivables:read",
        history: "receivables:history",
        settle_payment: "receivables:settle",
        attach_document: "receivables:documents:write"
      )

      include ReceivableProvenancePayload

      def index
        limit = params.fetch(:limit, 50).to_i.clamp(1, 200)
        receivables = apply_hospital_filter(tenant_receivables)
          .includes(:receivable_kind, :debtor_party, :creditor_party)
          .order(due_at: :asc)
          .limit(limit)

        render json: {
          data: receivables.map { |receivable| receivable_payload(receivable) },
          meta: {
            count: receivables.size,
            limit: limit
          }
        }
      end

      def show
        receivable = tenant_receivables
          .includes(:receivable_kind, :debtor_party, :creditor_party)
          .find(params[:id])

        render json: { data: receivable_payload(receivable) }
      end

      def history
        receivable = tenant_receivables
          .includes(:receivable_kind, :debtor_party, :creditor_party)
          .find(params[:id])
        events = receivable.receivable_events.order(sequence: :asc)
        documents = receivable.documents.includes(:document_events).order(signed_at: :asc)
        settlements = receivable.receivable_payment_settlements.includes(:anticipation_settlement_entries).order(paid_at: :asc)

        render json: {
          data: {
            receivable: receivable_payload(receivable),
            events: events.map { |event| event_payload(event) },
            documents: documents.map { |document| document_payload(document) },
            settlements: settlements.map { |settlement| settlement_payload(settlement) }
          }
        }
      end

      def settle_payment
        return unless enforce_string_payload_type!(settlement_params, :paid_amount)

        receivable = tenant_receivables.find(params[:id])
        result = receivable_settlement_service.call(
          receivable_id: receivable.id,
          receivable_allocation_id: settlement_params[:receivable_allocation_id],
          paid_amount: settlement_params[:paid_amount],
          paid_at: settlement_params[:paid_at].presence || Time.current,
          payment_reference: settlement_params[:payment_reference].presence || Current.idempotency_key,
          metadata: settlement_params[:metadata] || {}
        )

        render json: {
          data: settlement_payload(result.settlement).merge(
            replayed: result.replayed?,
            settlement_entries: result.settlement_entries.map { |entry| settlement_entry_payload(entry) }
          )
        }, status: (result.replayed? ? :ok : :created)
      rescue Receivables::SettlePayment::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue Receivables::SettlePayment::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      def attach_document
        receivable = tenant_receivables.find(params[:id])
        requested_actor_party_id = attach_document_params[:actor_party_id]
        enforce_actor_party_binding!(requested_actor_party_id) if requested_actor_party_id.present?

        result = receivable_document_service.call(
          receivable_id: receivable.id,
          raw_payload: attach_document_params.to_h,
          default_actor_party_id: current_actor_party_id,
          privileged_actor: privileged_actor?
        )

        render json: {
          data: document_payload(result.document).merge(replayed: result.replayed?)
        }, status: (result.replayed? ? :ok : :created)
      rescue Receivables::AttachSignedDocument::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue Receivables::AttachSignedDocument::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      private

      def receivable_payload(receivable)
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
          provenance: receivable_provenance_payload(receivable)
        }
      end

      def event_payload(event)
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

      def settlement_payload(settlement)
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

      def settlement_entry_payload(entry)
        {
          id: entry.id,
          anticipation_request_id: entry.anticipation_request_id,
          settled_amount: decimal_as_string(entry.settled_amount),
          settled_at: entry.settled_at&.iso8601
        }
      end

      def document_payload(document)
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
          events: document.document_events.order(occurred_at: :asc).map do |event|
            {
              id: event.id,
              event_type: event.event_type,
              occurred_at: event.occurred_at&.iso8601,
              actor_party_id: event.actor_party_id,
              request_id: event.request_id,
              payload: event.payload
            }
          end
        }
      end

      def decimal_as_string(value)
        value.to_d.to_s("F")
      end

      def settlement_params
        payload = params[:settlement].presence || params
        payload.permit(
          :receivable_allocation_id,
          :paid_amount,
          :paid_at,
          :payment_reference,
          metadata: {}
        )
      end

      def attach_document_params
        payload = params[:document].presence || params
        payload.permit(
          :actor_party_id,
          :document_type,
          :signature_method,
          :sha256,
          :storage_key,
          :blob_signed_id,
          :signed_at,
          :provider_envelope_id,
          :email_challenge_id,
          :whatsapp_challenge_id,
          metadata: {}
        )
      end

      def receivable_settlement_service
        Receivables::SettlePayment.new(
          tenant_id: Current.tenant_id,
          actor_party_id: current_actor_party_id,
          actor_role: Current.role,
          request_id: Current.request_id,
          idempotency_key: Current.idempotency_key,
          request_ip: request.remote_ip,
          user_agent: request.user_agent,
          endpoint_path: request.fullpath,
          http_method: request.method
        )
      end

      def receivable_document_service
        Receivables::AttachSignedDocument.new(
          tenant_id: Current.tenant_id,
          actor_role: Current.role,
          request_id: Current.request_id,
          idempotency_key: Current.idempotency_key,
          request_ip: request.remote_ip,
          user_agent: request.user_agent,
          endpoint_path: request.fullpath,
          http_method: request.method
        )
      end

      def tenant_receivables
        scope = Receivable.where(tenant_id: Current.tenant_id)
        return scope if privileged_actor?

        actor_party_id = current_actor_party_id
        raise AuthorizationError, "actor_party_required" if actor_party_id.blank?

        visibility_sql = <<~SQL.squish
          receivables.debtor_party_id = :actor_party_id
          OR receivables.creditor_party_id = :actor_party_id
          OR receivables.beneficiary_party_id = :actor_party_id
          OR EXISTS (
            SELECT 1
            FROM hospital_ownerships
            WHERE hospital_ownerships.tenant_id = receivables.tenant_id
              AND hospital_ownerships.organization_party_id = :actor_party_id
              AND hospital_ownerships.hospital_party_id = receivables.debtor_party_id
              AND hospital_ownerships.active = TRUE
          )
          OR EXISTS (
            SELECT 1
            FROM receivable_allocations
            WHERE receivable_allocations.tenant_id = receivables.tenant_id
              AND receivable_allocations.receivable_id = receivables.id
              AND (
                receivable_allocations.allocated_party_id = :actor_party_id
                OR receivable_allocations.physician_party_id = :actor_party_id
              )
          )
        SQL

        scope.where(visibility_sql, actor_party_id: actor_party_id)
      end

      def apply_hospital_filter(scope)
        hospital_party_id = params[:hospital_party_id].presence
        return scope if hospital_party_id.blank?

        scope.where(debtor_party_id: hospital_party_id)
      end

      def enforce_string_payload_type!(payload, key)
        return true if payload[key].is_a?(String)

        render_api_error(
          code: "invalid_#{key}_type",
          message: "#{key} must be provided as a string.",
          status: :unprocessable_entity
        )
        false
      end
    end
  end
end
