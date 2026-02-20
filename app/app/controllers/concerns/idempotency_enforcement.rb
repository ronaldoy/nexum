module IdempotencyEnforcement
  extend ActiveSupport::Concern

  IDEMPOTENCY_KEY_HEADER = "Idempotency-Key".freeze

  included do
    before_action :require_idempotency_key!, if: :mutation_request?
  end

  private

  def mutation_request?
    request.post? || request.patch? || request.put? || request.delete?
  end

  def require_idempotency_key!
    key = request.headers[IDEMPOTENCY_KEY_HEADER].to_s.strip
    return render_missing_idempotency_key if key.blank?

    Current.idempotency_key = key
  end

  def render_missing_idempotency_key
    render json: {
      error: {
        code: "missing_idempotency_key",
        message: "Idempotency-Key header is required for mutating requests.",
        request_id: request.request_id
      }
    }, status: :unprocessable_entity
  end
end
