class OpenapiDocsController < ActionController::API
  SPEC_PATH = Rails.root.join("..", "docs", "openapi", "v1.yaml").expand_path.freeze

  before_action :authenticate_docs_token

  def v1
    if SPEC_PATH.file?
      send_file SPEC_PATH, disposition: "inline", type: "application/yaml; charset=utf-8"
    else
      render json: {
        error: {
          code: "not_found",
          message: "OpenAPI v1 document was not found.",
          request_id: request.request_id
        }
      }, status: :not_found
    end
  end

  private

  def authenticate_docs_token
    expected_token = Rails.app.creds.option(:openapi_docs, :token, default: ENV["OPENAPI_DOCS_TOKEN"])
    if expected_token.blank?
      Rails.logger.error("openapi_docs_token_missing request_id=#{request.request_id}")
      return render_unauthorized
    end

    provided_token = request.headers["Authorization"]&.delete_prefix("Bearer ")&.strip
    return if provided_token.present? && ActiveSupport::SecurityUtils.secure_compare(provided_token, expected_token)

    render_unauthorized
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
