module Api
  module V1
    class KycProfilesController < Api::BaseController
      require_api_scopes(
        show: "kyc:read",
        create: "kyc:write",
        submit_document: "kyc:write"
      )

      def show
        kyc_profile = tenant_kyc_profiles.find(params[:id])
        authorize_party_access!(kyc_profile.party_id)

        render json: {
          data: kyc_profile_payload(kyc_profile)
        }
      end

      def create
        authorize_party_access!(create_params[:party_id]) if create_params[:party_id].present?

        result = kyc_profile_creation_service.call(
          create_params.to_h,
          default_party_id: current_actor_party_id
        )

        render json: {
          data: kyc_profile_payload(result.kyc_profile).merge(
            replayed: result.replayed?
          )
        }, status: (result.replayed? ? :ok : :created)
      rescue KycProfiles::Create::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue KycProfiles::Create::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      def submit_document
        kyc_profile = tenant_kyc_profiles.find(params[:id])
        authorize_party_access!(kyc_profile.party_id)

        result = kyc_document_submission_service.call(
          kyc_profile_id: kyc_profile.id,
          raw_payload: submit_document_params.to_h
        )

        render json: {
          data: kyc_document_payload(result.kyc_document).merge(
            replayed: result.replayed?
          )
        }, status: (result.replayed? ? :ok : :created)
      rescue KycProfiles::SubmitDocument::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue KycProfiles::SubmitDocument::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      private

      def create_params
        payload = params[:kyc_profile].presence || params
        payload.permit(
          :party_id,
          metadata: {}
        )
      end

      def submit_document_params
        payload = params[:kyc_document].presence || params
        payload.permit(
          :party_id,
          :document_type,
          :document_number,
          :issuing_country,
          :issuing_state,
          :issued_on,
          :expires_on,
          :is_key_document,
          :storage_key,
          :blob_signed_id,
          :sha256,
          metadata: {}
        )
      end

      def tenant_kyc_profiles
        KycProfile.where(tenant_id: Current.tenant_id).includes(:party, :kyc_documents, :kyc_events)
      end

      def kyc_profile_creation_service
        KycProfiles::Create.new(
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

      def kyc_document_submission_service
        KycProfiles::SubmitDocument.new(
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

      def kyc_profile_payload(profile)
        {
          id: profile.id,
          tenant_id: profile.tenant_id,
          party_id: profile.party_id,
          status: profile.status,
          risk_level: profile.risk_level,
          submitted_at: profile.submitted_at&.iso8601,
          reviewed_at: profile.reviewed_at&.iso8601,
          reviewer_party_id: profile.reviewer_party_id,
          metadata: profile.metadata || {},
          documents: profile.kyc_documents.order(created_at: :asc).map { |entry| kyc_document_payload(entry) },
          events: profile.kyc_events.order(occurred_at: :asc).map { |entry| kyc_event_payload(entry) }
        }
      end

      def kyc_document_payload(document)
        {
          id: document.id,
          tenant_id: document.tenant_id,
          kyc_profile_id: document.kyc_profile_id,
          party_id: document.party_id,
          document_type: document.document_type,
          document_number: document.document_number,
          issuing_country: document.issuing_country,
          issuing_state: document.issuing_state,
          issued_on: document.issued_on&.iso8601,
          expires_on: document.expires_on&.iso8601,
          is_key_document: document.is_key_document,
          status: document.status,
          verified_at: document.verified_at&.iso8601,
          rejection_reason: document.rejection_reason,
          storage_key: document.storage_key,
          sha256: document.sha256,
          metadata: document.metadata || {}
        }
      end

      def kyc_event_payload(event)
        {
          id: event.id,
          tenant_id: event.tenant_id,
          kyc_profile_id: event.kyc_profile_id,
          party_id: event.party_id,
          actor_party_id: event.actor_party_id,
          event_type: event.event_type,
          occurred_at: event.occurred_at&.iso8601,
          request_id: event.request_id,
          payload: event.payload || {}
        }
      end
    end
  end
end
