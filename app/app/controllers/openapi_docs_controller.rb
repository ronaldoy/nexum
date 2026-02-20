class OpenapiDocsController < ActionController::API
  SPEC_PATH = Rails.root.join("..", "docs", "openapi", "v1.yaml").expand_path.freeze
  AUTHORIZATION_HEADER = "Authorization".freeze

  before_action :authenticate_docs_token

  def v1
    return send_file SPEC_PATH, disposition: "inline", type: "application/yaml; charset=utf-8" if SPEC_PATH.file?

    render_not_found
  end

  private

  def authenticate_docs_token
    expected_token = openapi_docs_token
    return render_missing_token if expected_token.blank?
    return if valid_provided_token?(expected_token)

    log_invalid_token
    render_unauthorized
  end

  def openapi_docs_token
    Rails.app.creds.option(:openapi_docs, :token, default: ENV["OPENAPI_DOCS_TOKEN"])
  end

  def provided_token
    request.headers[AUTHORIZATION_HEADER]&.delete_prefix("Bearer ")&.strip
  end

  def valid_provided_token?(expected_token)
    provided = provided_token
    provided.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected_token)
  end

  def render_missing_token
    Rails.logger.error("openapi_docs_token_missing request_id=#{request.request_id}")
    render_unauthorized
  end

  def log_invalid_token
    Rails.logger.warn("openapi_docs_token_invalid request_id=#{request.request_id} remote_ip=#{request.remote_ip}")
  end

  def render_not_found
    render json: {
      error: {
        code: "not_found",
        message: "OpenAPI v1 document was not found.",
        request_id: request.request_id
      }
    }, status: :not_found
  end

  def render_unauthorized
    render json: {
      error: {
        code: "unauthorized",
        message: "Valid Bearer token is required.",
        request_id: request.request_id
      }
    }, status: :unauthorized
  end
end
