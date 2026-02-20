module Api
  module V1
    class KycProfilesController < Api::BaseController
      require_api_scopes(
        show: "kyc:read",
        create: "kyc:write",
        submit_document: "kyc:write"
      )

      CREATE_PERMITTED_FIELDS = [
        :party_id,
        { metadata: {} }
      ].freeze

      SUBMIT_DOCUMENT_PERMITTED_FIELDS = [
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
        { metadata: {} }
      ].freeze

      def show
        render_show_response(load_kyc_profile_with_access!(params[:id]))
      end

      def create
        payload = create_params
        authorize_create_party_access!(payload)
        result = kyc_profile_creation_result(payload)

        render_create_response(result)
      rescue ::KycProfiles::Create::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue ::KycProfiles::Create::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      def submit_document
        kyc_profile = load_kyc_profile_with_access!(params[:id])
        result = kyc_document_submission_result(kyc_profile)

        render_submit_document_response(result)
      rescue ::KycProfiles::SubmitDocument::IdempotencyConflict => error
        render_api_error(code: error.code, message: error.message, status: :conflict)
      rescue ::KycProfiles::SubmitDocument::ValidationError => error
        render_api_error(code: error.code, message: error.message, status: :unprocessable_entity)
      end

      private

      def load_kyc_profile_with_access!(kyc_profile_id)
        kyc_profile = tenant_kyc_profiles.find(kyc_profile_id)
        authorize_party_access!(kyc_profile.party_id)
        kyc_profile
      end

      def render_show_response(kyc_profile)
        render json: { data: payload_presenter.profile(kyc_profile) }
      end

      def authorize_create_party_access!(payload)
        party_id = payload[:party_id]
        authorize_party_access!(party_id) if party_id.present?
      end

      def kyc_profile_creation_result(payload)
        kyc_profile_creation_service.call(
          payload.to_h,
          default_party_id: current_actor_party_id
        )
      end

      def render_create_response(result)
        render json: {
          data: payload_presenter.profile(result.kyc_profile).merge(
            replayed: result.replayed?
          )
        }, status: (result.replayed? ? :ok : :created)
      end

      def kyc_document_submission_result(kyc_profile)
        kyc_document_submission_service.call(
          kyc_profile_id: kyc_profile.id,
          raw_payload: submit_document_params.to_h
        )
      end

      def render_submit_document_response(result)
        render json: {
          data: payload_presenter.document(result.kyc_document).merge(
            replayed: result.replayed?
          )
        }, status: (result.replayed? ? :ok : :created)
      end

      def create_params
        payload = params[:kyc_profile].presence || params
        payload.permit(*CREATE_PERMITTED_FIELDS)
      end

      def submit_document_params
        payload = params[:kyc_document].presence || params
        payload.permit(*SUBMIT_DOCUMENT_PERMITTED_FIELDS)
      end

      def tenant_kyc_profiles
        KycProfile.where(tenant_id: Current.tenant_id).includes(:party, :kyc_documents, :kyc_events)
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

      def kyc_profile_creation_service
        ::KycProfiles::Create.new(
          **request_context_attributes
        )
      end

      def kyc_document_submission_service
        ::KycProfiles::SubmitDocument.new(
          **request_context_attributes
        )
      end

      def payload_presenter
        @payload_presenter ||= KycProfilePayloadPresenter.new
      end
    end
  end
end
