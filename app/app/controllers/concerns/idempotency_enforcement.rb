module IdempotencyEnforcement
  extend ActiveSupport::Concern

  included do
    before_action :require_idempotency_key!, if: :mutation_request?
  end

  private

  def mutation_request?
    request.post? || request.patch? || request.put? || request.delete?
  end

  def require_idempotency_key!
    key = request.headers["Idempotency-Key"].to_s.strip

    if key.blank?
      render json: {
        error: {
          code: "missing_idempotency_key",
          message: "Idempotency-Key header is required for mutating requests.",
          request_id: request.request_id
        }
      }, status: :unprocessable_entity
      return
    end

    Current.idempotency_key = key
  end
end
