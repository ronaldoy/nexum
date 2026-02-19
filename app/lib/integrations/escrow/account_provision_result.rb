module Integrations
  module Escrow
    AccountProvisionResult = Struct.new(
      :provider_account_id,
      :provider_request_id,
      :status,
      :metadata,
      keyword_init: true
    )
  end
end
