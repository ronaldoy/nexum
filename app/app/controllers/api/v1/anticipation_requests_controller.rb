module Api
  module V1
    class AnticipationRequestsController < Api::BaseController
      before_action only: :create do
        require_api_scope!("anticipation_requests:write")
      end
      before_action only: :issue_challenges do
        require_api_scope!("anticipation_requests:challenge")
      end
      before_action only: :confirm do
        require_api_scope!("anticipation_requests:confirm")
      end

      def create
        result = anticipation_creation_service.call(
          create_params.to_h,
          default_requester_party_id: Current.user&.party_id
        )

        render json: {
          data: anticipation_payload(result.anticipation_request, replayed: result.replayed?)
        }, status: (result.replayed? ? :ok : :created)
      rescue AnticipationRequests::Create::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue AnticipationRequests::Create::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      def issue_challenges
        result = challenge_issue_service.call(
          anticipation_request_id: params[:id],
          email_destination: challenge_issue_params[:email_destination],
          whatsapp_destination: challenge_issue_params[:whatsapp_destination]
        )

        render json: {
          data: {
            anticipation_request_id: result.anticipation_request.id,
            replayed: result.replayed?,
            challenges: result.challenges.map do |challenge|
              {
                id: challenge.id,
                delivery_channel: challenge.delivery_channel,
                destination_masked: challenge.destination_masked,
                status: challenge.status,
                expires_at: challenge.expires_at&.iso8601
              }
            end
          }
        }, status: (result.replayed? ? :ok : :created)
      rescue AnticipationRequests::IssueChallenges::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue AnticipationRequests::IssueChallenges::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      def confirm
        result = anticipation_confirmation_service.call(
          anticipation_request_id: params[:id],
          email_code: confirmation_params[:email_code],
          whatsapp_code: confirmation_params[:whatsapp_code]
        )

        render json: {
          data: anticipation_payload(result.anticipation_request, replayed: result.replayed?)
        }, status: :ok
      rescue AnticipationRequests::Confirm::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue AnticipationRequests::Confirm::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      private

      def create_params
        payload = params[:anticipation_request].presence || params
        payload.permit(
          :receivable_id,
          :receivable_allocation_id,
          :requester_party_id,
          :requested_amount,
          :discount_rate,
          :channel,
          metadata: {}
        )
      end

      def confirmation_params
        payload = params[:confirmation].presence || params
        payload.permit(:email_code, :whatsapp_code)
      end

      def challenge_issue_params
        payload = params[:challenge_issue].presence || params
        payload.permit(:email_destination, :whatsapp_destination)
      end

      def anticipation_creation_service
        AnticipationRequests::Create.new(
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

      def challenge_issue_service
        AnticipationRequests::IssueChallenges.new(
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

      def anticipation_confirmation_service
        AnticipationRequests::Confirm.new(
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

      def anticipation_payload(record, replayed:)
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
          replayed: replayed
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
