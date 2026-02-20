module ApiTokenAuthentication
  extend ActiveSupport::Concern
  INVALID_TOKEN_CODE = "invalid_token".freeze
  INVALID_TOKEN_MESSAGE = "Authentication token is invalid or expired.".freeze

  included do
    before_action :authenticate_api_token!
  end

  private

  def authenticate_api_token!
    raw_token = bearer_token
    tenant_id = tenant_id_from_raw_token(raw_token)
    return render_invalid_token unless tenant_id

    bootstrap_database_tenant_context!(tenant_id)
    token = authenticated_api_token(raw_token)
    return render_invalid_token_with_cleared_context unless valid_authenticated_token?(token, tenant_id)

    hydrate_request_context!(token)
    return unless invalid_token_user_binding?(token)

    render_invalid_token_with_cleared_context
  rescue RequestContext::ContextError
    render json: {
      error: {
        code: "request_context_unavailable",
        message: "Authentication context could not be established.",
        request_id: request.request_id
      }
    }, status: :service_unavailable
  end

  def tenant_id_from_raw_token(raw_token)
    ApiAccessToken.tenant_id_from_token(raw_token)
  end

  def authenticated_api_token(raw_token)
    ApiAccessToken.authenticate(raw_token)
  end

  def valid_authenticated_token?(token, tenant_id)
    token.present? && token.tenant_id.to_s == tenant_id.to_s
  end

  def hydrate_request_context!(token)
    token.touch_last_used!
    Current.tenant_id = token.tenant_id
    Current.api_access_token = token
    Current.user = token.user
  end

  def invalid_token_user_binding?(token)
    Current.user.present? && Current.user.tenant_id.to_s != token.tenant_id.to_s
  end

  def render_invalid_token
    render_unauthorized(code: INVALID_TOKEN_CODE, message: INVALID_TOKEN_MESSAGE)
  end

  def render_invalid_token_with_cleared_context
    clear_bootstrap_database_tenant_context!
    render_invalid_token
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
