module Outbox
  class EventRouter
    class DeliveryError < StandardError
      attr_reader :code

      def initialize(code:, message:)
        @code = code.to_s
        super(message)
      end
    end

    HANDLERS = {
      "ANTICIPATION_ESCROW_PAYOUT_REQUESTED" => Integrations::Escrow::DispatchPayout,
      "RECEIVABLE_ESCROW_EXCESS_PAYOUT_REQUESTED" => Integrations::Escrow::DispatchPayout,
      "RECEIVABLE_ESCROW_PAYMENT_INSTRUCTIONS_REFRESH_REQUESTED" => Integrations::Escrow::RefreshPaymentInstructions,
      "ANTICIPATION_FIDC_FUNDING_REQUESTED" => Integrations::Fidc::DispatchOperation,
      "RECEIVABLE_FIDC_SETTLEMENT_REPORTED" => Integrations::Fidc::DispatchOperation,
      "RECEIVABLE_HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_REQUESTED" => Integrations::HospitalApi::DispatchPaymentInstructions
    }.freeze

    def call(outbox_event:)
      handler = HANDLERS[outbox_event.event_type]
      return :noop if handler.blank?

      handler.new.call(outbox_event: outbox_event)
    rescue Integrations::Escrow::Error => error
      raise DeliveryError.new(code: error.code, message: error.message)
    rescue Integrations::Fidc::Error => error
      raise DeliveryError.new(code: error.code, message: error.message)
    rescue Integrations::HospitalApi::Error => error
      raise DeliveryError.new(code: error.code, message: error.message)
    end
  end
end
