module Api
  module V1
    class AnticipationRequestsController < Api::BaseController
      require_api_scopes(
        create: "anticipation_requests:write",
        issue_challenges: "anticipation_requests:challenge",
        confirm: "anticipation_requests:confirm"
      )

      include ReceivableProvenancePayload

      CREATE_PERMITTED_FIELDS = [
        :receivable_id,
        :receivable_allocation_id,
        :requester_party_id,
        :requested_amount,
        :discount_rate,
        :channel,
        { metadata: {} }
      ].freeze

      CONFIRMATION_PERMITTED_FIELDS = %i[email_code whatsapp_code].freeze
      CHALLENGE_ISSUE_PERMITTED_FIELDS = %i[email_destination whatsapp_destination].freeze

      def create
        payload = create_params
        authorize_requester_party_access!(payload)
        return unless create_payload_types_valid?(payload)

        result = anticipation_creation_result(payload)
        render_create_response(result)
      rescue ::AnticipationRequests::Create::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue ::AnticipationRequests::Create::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      def issue_challenges
        anticipation_request = load_anticipation_request_with_access!(params[:id])
        result = issue_challenges_result(anticipation_request)

        render_issue_challenges_response(result)
      rescue ::AnticipationRequests::IssueChallenges::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue ::AnticipationRequests::IssueChallenges::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      def confirm
        anticipation_request = load_anticipation_request_with_access!(params[:id])
        result = anticipation_confirmation_result(anticipation_request)

        render_confirm_response(result)
      rescue ::AnticipationRequests::Confirm::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue ::AnticipationRequests::Confirm::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      private

      def authorize_requester_party_access!(payload)
        requester_party_id = payload[:requester_party_id]
        authorize_party_access!(requester_party_id) if requester_party_id.present?
      end

      def create_payload_types_valid?(payload)
        return false unless enforce_string_payload_type!(payload, :requested_amount)
        return false unless enforce_string_payload_type!(payload, :discount_rate)

        true
      end

      def anticipation_creation_result(payload)
        anticipation_creation_service.call(
          payload.to_h,
          default_requester_party_id: current_actor_party_id
        )
      end

      def render_create_response(result)
        render json: {
          data: payload_presenter.anticipation_request(result.anticipation_request, replayed: result.replayed?)
        }, status: (result.replayed? ? :ok : :created)
      end

      def load_anticipation_request_with_access!(anticipation_request_id)
        anticipation_request = tenant_anticipation_requests.find(anticipation_request_id)
        authorize_party_access!(anticipation_request.requester_party_id)
        anticipation_request
      end

      def issue_challenges_result(anticipation_request)
        payload = challenge_issue_params
        challenge_issue_service.call(
          anticipation_request_id: anticipation_request.id,
          email_destination: payload[:email_destination],
          whatsapp_destination: payload[:whatsapp_destination]
        )
      end

      def render_issue_challenges_response(result)
        render json: { data: payload_presenter.challenge_issue(result) }, status: (result.replayed? ? :ok : :created)
      end

      def anticipation_confirmation_result(anticipation_request)
        payload = confirmation_params
        anticipation_confirmation_service.call(
          anticipation_request_id: anticipation_request.id,
          email_code: payload[:email_code],
          whatsapp_code: payload[:whatsapp_code]
        )
      end

      def render_confirm_response(result)
        render json: {
          data: payload_presenter.anticipation_request(result.anticipation_request, replayed: result.replayed?)
        }, status: :ok
      end

      def create_params
        payload = params[:anticipation_request].presence || params
        payload.permit(*CREATE_PERMITTED_FIELDS)
      end

      def confirmation_params
        payload = params[:confirmation].presence || params
        payload.permit(*CONFIRMATION_PERMITTED_FIELDS)
      end

      def challenge_issue_params
        payload = params[:challenge_issue].presence || params
        payload.permit(*CHALLENGE_ISSUE_PERMITTED_FIELDS)
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

      def anticipation_creation_service
        ::AnticipationRequests::Create.new(
          **request_context_attributes
        )
      end

      def challenge_issue_service
        ::AnticipationRequests::IssueChallenges.new(
          **request_context_attributes
        )
      end

      def anticipation_confirmation_service
        ::AnticipationRequests::Confirm.new(
          **request_context_attributes
        )
      end

      def tenant_anticipation_requests
        AnticipationRequest.where(tenant_id: Current.tenant_id)
      end

      def payload_presenter
        @payload_presenter ||= AnticipationRequestPayloadPresenter.new(
          provenance_resolver: method(:receivable_provenance_payload)
        )
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
