module Api
  class BaseController < ActionController::API
    include ApiTokenAuthentication
    include IdempotencyEnforcement
    include RequestContext

    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

    private

    def resolved_tenant_id
      Current.api_access_token&.tenant_id || Current.user&.tenant_id
    end

    def resolved_actor_id
      Current.user&.party_id || Current.user&.id || Current.api_access_token&.id
    end

    def resolved_role
      Current.user&.role || "integration_api"
    end

    def render_not_found
      render_api_error(code: "not_found", message: "Resource not found.", status: :not_found)
    end

    def render_api_error(code:, message:, status:)
      render json: {
        error: {
          code: code,
          message: message,
          request_id: request.request_id
        }
      }, status: status
    end

    def require_api_scope!(scope)
      token_scopes = Array(Current.api_access_token&.scopes)
      return if token_scopes.include?(scope)

      render_api_error(
        code: "insufficient_scope",
        message: "Missing required scope: #{scope}.",
        status: :forbidden
      )
    end
  end
end
