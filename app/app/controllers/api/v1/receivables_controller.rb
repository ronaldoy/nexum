module Api
  module V1
    class ReceivablesController < Api::BaseController
      require_api_scopes(
        index: "receivables:read",
        show: "receivables:read",
        create: "receivables:write",
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
          data: receivables.map { |receivable| payload_presenter.receivable(receivable) },
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

        render json: { data: payload_presenter.receivable(receivable) }
      end

      def create
        return unless enforce_string_payload_type!(create_params, :gross_amount)
        return unless enforce_optional_nested_string_payload_type!(create_params[:allocation], :gross_amount, prefix: "allocation")
        return unless enforce_optional_nested_string_payload_type!(create_params[:allocation], :tax_reserve_amount, prefix: "allocation")

        result = receivable_create_service.call(create_params.to_h)
        receivable = result.receivable

        render json: {
          data: payload_presenter.receivable(receivable).merge(
            replayed: result.replayed?,
            receivable_allocation_id: result.allocation&.id
          )
        }, status: (result.replayed? ? :ok : :created)
      rescue ::Receivables::Create::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue ::Receivables::Create::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
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
            receivable: payload_presenter.receivable(receivable),
            events: events.map { |event| payload_presenter.event(event) },
            documents: documents.map { |document| payload_presenter.document(document) },
            settlements: settlements.map { |settlement| payload_presenter.settlement(settlement) }
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
          data: payload_presenter.settlement(result.settlement).merge(
            replayed: result.replayed?,
            settlement_entries: result.settlement_entries.map { |entry| payload_presenter.settlement_entry(entry) }
          )
        }, status: (result.replayed? ? :ok : :created)
      rescue ::Receivables::SettlePayment::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue ::Receivables::SettlePayment::ValidationError => error
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
          data: payload_presenter.document(result.document).merge(replayed: result.replayed?)
        }, status: (result.replayed? ? :ok : :created)
      rescue ::Receivables::AttachSignedDocument::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue ::Receivables::AttachSignedDocument::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      private

      def payload_presenter
        @payload_presenter ||= Api::V1::Receivables::PayloadPresenter.new(
          provenance_resolver: method(:receivable_provenance_payload)
        )
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

      def create_params
        payload = params[:receivable].presence || params
        payload.permit(
          :external_reference,
          :receivable_kind_code,
          :debtor_party_id,
          :creditor_party_id,
          :beneficiary_party_id,
          :gross_amount,
          :currency,
          :performed_at,
          :due_at,
          :cutoff_at,
          metadata: {},
          allocation: [ :allocated_party_id, :physician_party_id, :gross_amount, :tax_reserve_amount, :eligible_for_anticipation, { metadata: {} } ]
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
        ::Receivables::SettlePayment.new(
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

      def receivable_create_service
        ::Receivables::Create.new(
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

      def receivable_document_service
        ::Receivables::AttachSignedDocument.new(
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
        if actor_party_id.blank?
          raise AuthorizationError.new(code: "actor_party_required", message: "Access denied.")
        end

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

      def enforce_optional_nested_string_payload_type!(payload, key, prefix:)
        return true if payload.blank?

        raw_value = payload[key] || payload[key.to_s]
        return true if raw_value.blank? || raw_value.is_a?(String)

        render_api_error(
          code: "invalid_#{prefix}_#{key}_type",
          message: "#{prefix}.#{key} must be provided as a string.",
          status: :unprocessable_entity
        )
        false
      end
    end
  end
end
