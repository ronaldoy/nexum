module Api
  module V1
    module Oauth
      class TokensController < ActionController::API
        require "base64"
        include RequestContext
        include IdempotencyEnforcement

        rescue_from RequestContext::ContextError, with: :render_request_context_error
        before_action :set_oauth_response_headers

        def create
          with_oauth_error_handling do
            result = oauth_token_issue_result
            return if performed?

            render_token_response(**result)
          end
        end

        private

        def with_oauth_error_handling
          yield
        rescue PartnerApplication::AuthenticationError
          render_invalid_client
        rescue PartnerApplication::ScopeError => error
          render_invalid_scope(error.message)
        rescue ActiveRecord::RecordInvalid => error
          render_invalid_request(error.record.errors.full_messages.to_sentence)
        end

        def oauth_token_issue_result
          return render_unsupported_grant_type unless client_credentials_grant?

          credentials = client_credentials
          return render_invalid_client unless client_credentials_present?(credentials)

          application = find_active_application(credentials.fetch(:client_id))
          return render_invalid_client if application.blank?

          {
            application: application,
            issued: issue_access_token(application:, client_secret: credentials.fetch(:client_secret))
          }
        end

        def resolved_tenant_id
          @resolved_tenant_id ||= resolve_tenant_id_from_slug(params[:tenant_slug])
        end

        def resolved_actor_id
          nil
        end

        def resolved_role
          "oauth_client"
        end

        def client_credentials_grant?
          grant_type == "client_credentials"
        end

        def oauth_params
          params.permit(:grant_type, :client_id, :client_secret, :scope)
        end

        def client_credentials_present?(credentials)
          credentials[:client_id].present? && credentials[:client_secret].present?
        end

        def client_credentials
          basic = basic_authorization_credentials
          return basic if basic[:client_id].present?

          {
            client_id: oauth_params[:client_id].to_s.strip,
            client_secret: oauth_params[:client_secret].to_s
          }
        end

        def basic_authorization_credentials
          scheme, value = request.authorization.to_s.split(" ", 2)
          return { client_id: nil, client_secret: nil } unless scheme&.casecmp("Basic")&.zero?

          decoded = Base64.strict_decode64(value.to_s)
          client_id, client_secret = decoded.split(":", 2)
          {
            client_id: client_id.to_s.strip,
            client_secret: client_secret.to_s
          }
        rescue ArgumentError
          { client_id: nil, client_secret: nil }
        end

        def grant_type
          oauth_params[:grant_type].to_s
        end

        def find_active_application(client_id)
          PartnerApplication.where(tenant_id: Current.tenant_id, client_id: client_id, active: true).first
        end

        def issue_access_token(application:, client_secret:)
          application.authenticate_secret!(client_secret)
          Current.partner_application = application
          application.issue_access_token!(
            requested_scopes: oauth_params[:scope],
            audit_context: token_audit_context
          )
        end

        def token_audit_context
          {
            actor_party_id: nil,
            ip_address: request.remote_ip,
            user_agent: request.user_agent,
            request_id: request.request_id,
            endpoint_path: request.fullpath,
            http_method: request.method,
            channel: "API",
            metadata: token_audit_metadata
          }
        end

        def token_audit_metadata
          {
            "grant_type" => grant_type,
            "tenant_slug" => params[:tenant_slug]
          }
        end

        def render_token_response(application:, issued:)
          render json: {
            access_token: issued.fetch(:raw_token),
            token_type: "Bearer",
            expires_in: application.token_ttl_minutes.minutes.to_i,
            scope: issued.fetch(:scopes).join(" ")
          }, status: :ok
        end

        def set_oauth_response_headers
          response.headers["Cache-Control"] = "no-store"
          response.headers["Pragma"] = "no-cache"
        end

        def render_request_context_error
          render_oauth_error(
            code: "temporarily_unavailable",
            description: "Authentication context could not be established.",
            status: :service_unavailable
          )
        end

        def render_unsupported_grant_type
          render_oauth_error(
            code: "unsupported_grant_type",
            description: "Only client_credentials is supported.",
            status: :bad_request
          )
        end

        def render_invalid_client
          render_oauth_error(
            code: "invalid_client",
            description: "Client authentication failed.",
            status: :unauthorized
          )
        end

        def render_invalid_scope(description)
          render_oauth_error(code: "invalid_scope", description: description, status: :bad_request)
        end

        def render_invalid_request(description)
          render_oauth_error(code: "invalid_request", description: description, status: :unprocessable_entity)
        end

        def render_oauth_error(code:, description:, status:)
          render json: {
            error: code,
            error_description: description,
            request_id: request.request_id
          }, status: status
        end
      end
    end
  end
end
