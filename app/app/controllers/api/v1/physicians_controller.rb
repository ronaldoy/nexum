module Api
  module V1
    class PhysiciansController < Api::BaseController
      require_api_scopes(
        create: "physicians:write",
        show: "physicians:read"
      )

      def create
        result = physician_create_service.call(physician_params.to_h)

        render json: {
          data: physician_payload(result.physician, result.party).merge(replayed: result.replayed?)
        }, status: (result.replayed? ? :ok : :created)
      rescue Physicians::Create::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue Physicians::Create::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      def show
        physician = tenant_physicians.find(params[:id])
        render json: {
          data: physician_payload(physician, physician.party)
        }
      end

      private

      def physician_params
        payload = params[:physician].presence || params
        payload.permit(
          :full_name,
          :display_name,
          :email,
          :phone,
          :document_number,
          :external_ref,
          :crm_number,
          :crm_state,
          metadata: {},
          party_metadata: {}
        )
      end

      def physician_create_service
        Physicians::Create.new(
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

      def tenant_physicians
        scope = Physician.where(tenant_id: Current.tenant_id).includes(:party)
        return scope if privileged_actor?

        actor_party_id = current_actor_party_id
        raise AuthorizationError.new(code: "actor_party_required", message: "Access denied.") if actor_party_id.blank?

        scope.where(party_id: actor_party_id)
      end

      def physician_payload(physician, party)
        {
          id: physician.id,
          tenant_id: physician.tenant_id,
          party: {
            id: party.id,
            external_ref: party.external_ref,
            kind: party.kind,
            legal_name: party.legal_name,
            display_name: party.display_name,
            document_type: party.document_type,
            document_number: party.document_number
          },
          full_name: physician.full_name,
          email: physician.email,
          phone: physician.phone,
          crm_number: physician.crm_number,
          crm_state: physician.crm_state,
          active: physician.active,
          metadata: physician.metadata || {}
        }
      end
    end
  end
end
