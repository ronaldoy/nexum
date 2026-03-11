module Integrations
  module Fidc
    OperationResult = Struct.new(
      :provider_reference,
      :status,
      :metadata,
      keyword_init: true
    )
  end
end
