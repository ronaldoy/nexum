module Integrations
  module Fdic
    OperationResult = Struct.new(
      :provider_reference,
      :status,
      :metadata,
      keyword_init: true
    )
  end
end
