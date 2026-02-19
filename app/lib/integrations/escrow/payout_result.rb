module Integrations
  module Escrow
    PayoutResult = Struct.new(
      :provider_transfer_id,
      :status,
      :metadata,
      keyword_init: true
    )
  end
end
