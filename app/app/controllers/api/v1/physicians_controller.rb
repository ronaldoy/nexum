module Api
  module V1
    class PhysiciansController < Api::BaseController
      require_api_scopes(
        create: "physicians:write",
        show: "physicians:read"
      )

      CREATE_PERMITTED_FIELDS = [
        :full_name,
        :display_name,
        :email,
        :phone,
        :document_number,
        :external_ref,
        :crm_number,
        :crm_state,
        { metadata: {} },
        { party_metadata: {} }
      ].freeze

      def create
        result = physician_creation_result
        render_create_response(result)
      rescue ::Physicians::Create::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue ::Physicians::Create::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      def show
        render_show_response(load_physician_with_access!(params[:id]))
      end

      private

      def physician_creation_result
        physician_create_service.call(physician_params.to_h)
      end

      def render_create_response(result)
        render json: {
          data: payload_presenter.physician(result.physician, result.party).merge(replayed: result.replayed?)
        }, status: (result.replayed? ? :ok : :created)
      end

      def load_physician_with_access!(physician_id)
        tenant_physicians.find(physician_id)
      end

      def render_show_response(physician)
        render json: { data: payload_presenter.physician(physician, physician.party) }
      end

      def physician_params
        payload = params[:physician].presence || params
        payload.permit(*CREATE_PERMITTED_FIELDS)
      end

      def request_context_attributes
        {
          tenant_id: Current.tenant_id,
          actor_role: Current.role,
          request_id: Current.request_id,
          idempotency_key: Current.idempotency_key,
          request_ip: request.remote_ip,
          user_agent: request.user_agent,
          endpoint_path: request.fullpath,
          http_method: request.method
        }
      end

      def physician_create_service
        ::Physicians::Create.new(
          **request_context_attributes
        )
      end

      def tenant_physicians
        scope = Physician.where(tenant_id: Current.tenant_id).includes(:party)
        return scope if privileged_actor?

        actor_party_id = require_actor_party_id!
        scope.where(party_id: actor_party_id)
      end

      def require_actor_party_id!
        actor_party_id = current_actor_party_id
        return actor_party_id if actor_party_id.present?

        raise AuthorizationError.new(code: "actor_party_required", message: "Access denied.")
      end

      def payload_presenter
        @payload_presenter ||= PhysicianPayloadPresenter.new
      end
    end
  end
end
