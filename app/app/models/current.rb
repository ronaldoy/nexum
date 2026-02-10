class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :tenant_id, :actor_id, :role, :api_access_token, :idempotency_key, :request_id
end
