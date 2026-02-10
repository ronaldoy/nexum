module ApiTokenAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_api_token!
  end

  private

  def authenticate_api_token!
    token = ApiAccessToken.authenticate(bearer_token)

    unless token
      render_unauthorized(code: "invalid_token", message: "Authentication token is invalid or expired.")
      return
    end

    token.touch_last_used!
    Current.api_access_token = token
    Current.user = token.user
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
