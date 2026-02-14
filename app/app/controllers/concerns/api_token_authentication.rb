module ApiTokenAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_api_token!
  end

  private

  def authenticate_api_token!
    raw_token = bearer_token
    tenant_id = ApiAccessToken.tenant_id_from_token(raw_token)
    unless tenant_id
      render_unauthorized(code: "invalid_token", message: "Authentication token is invalid or expired.")
      return
    end

    bootstrap_database_tenant_context!(tenant_id)

    token = ApiAccessToken.authenticate(raw_token)

    unless token
      clear_bootstrap_database_tenant_context!
      render_unauthorized(code: "invalid_token", message: "Authentication token is invalid or expired.")
      return
    end

    if token.tenant_id.to_s != tenant_id.to_s
      clear_bootstrap_database_tenant_context!
      render_unauthorized(code: "invalid_token", message: "Authentication token is invalid or expired.")
      return
    end

    token.touch_last_used!
    Current.tenant_id = token.tenant_id
    Current.api_access_token = token
    Current.user = token.user

    if Current.user && Current.user.tenant_id.to_s != token.tenant_id.to_s
      clear_bootstrap_database_tenant_context!
      render_unauthorized(code: "invalid_token", message: "Authentication token is invalid or expired.")
      return
    end
  rescue RequestContext::ContextError
    render json: {
      error: {
        code: "request_context_unavailable",
        message: "Authentication context could not be established.",
        request_id: request.request_id
      }
    }, status: :service_unavailable
  end

  def bearer_token
    scheme, value = request.authorization.to_s.split(" ", 2)
    return nil unless scheme&.casecmp("Bearer")&.zero?

    value&.strip
  end

  def render_unauthorized(code:, message:)
    render json: {
      error: {
        code: code,
        message: message,
        request_id: request.request_id
      }
    }, status: :unauthorized
  end
end
