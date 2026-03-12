module Integrations
  module Escrow
    PayoutResult = Struct.new(
      :provider_transfer_id,
      :status,
      :provider_status,
      :provider_fee_amount,
      :provider_fee_currency,
      :provider_source_account_id,
      :provider_destination_account_id,
      :provider_end_to_end_id,
      :confirmed_at,
      :batch_id,
      :metadata,
      keyword_init: true
    )
  end
end
