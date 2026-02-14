class OpenapiDocsController < ActionController::API
  SPEC_PATH = Rails.root.join("..", "docs", "openapi", "v1.yaml").expand_path.freeze

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
end
