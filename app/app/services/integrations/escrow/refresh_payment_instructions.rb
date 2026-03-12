module Integrations
  module Escrow
    class RefreshPaymentInstructions
      TARGET_TYPE = "Receivable".freeze

      RefreshInputs = Struct.new(
        :payload,
        :receivable,
        :receivable_allocation,
        :operational_party,
        keyword_init: true
      )

      def call(outbox_event:)
        inputs = build_refresh_inputs(outbox_event)
        result = EnsurePaymentInstructions.new.call(
          tenant_id: outbox_event.tenant_id,
          receivable: inputs.receivable,
          receivable_allocation: inputs.receivable_allocation,
          idempotency_key: inputs.payload["payment_instruction_idempotency_key"].to_s.presence,
          requested_provider_code: inputs.payload["provider"].to_s.presence,
          allow_provisioning: true,
          allow_provider_fetch: true,
          persist_payment_instructions: true
        )

        create_action_log!(
          outbox_event: outbox_event,
          action_type: "ESCROW_PAYMENT_INSTRUCTIONS_REFRESHED",
          success: true,
          target_id: inputs.receivable.id,
          metadata: {
            "receivable_allocation_id" => inputs.receivable_allocation.id,
            "operational_party_id" => inputs.operational_party.id,
            "provider" => result.provider_code
          }
        )

        result
      rescue Error => error
        create_action_log!(
          outbox_event: outbox_event,
          action_type: "ESCROW_PAYMENT_INSTRUCTIONS_REFRESH_FAILED",
          success: false,
          target_id: outbox_event.aggregate_id,
          metadata: {
            "error_code" => error.code,
            "error_message" => error.message
          }
        ) if outbox_event.present?
        raise
      end

      private

      def build_refresh_inputs(outbox_event)
        payload = normalize_metadata(outbox_event.payload || {})
        receivable = Receivable.where(tenant_id: outbox_event.tenant_id).find(payload.fetch("receivable_id"))
        receivable_allocation = ReceivableAllocation.where(
          tenant_id: outbox_event.tenant_id,
          receivable_id: receivable.id
        ).find(payload.fetch("receivable_allocation_id"))

        RefreshInputs.new(
          payload: payload,
          receivable: receivable,
          receivable_allocation: receivable_allocation,
          operational_party: receivable_allocation.allocated_party
        )
      rescue KeyError => error
        raise ValidationError.new(
          code: "payment_instructions_refresh_payload_invalid",
          message: "Payment instructions refresh payload is missing required fields.",
          details: { missing_key: error.key }
        )
      end

      def create_action_log!(outbox_event:, action_type:, success:, target_id:, metadata:)
        ActionIpLog.create!(
          tenant_id: outbox_event.tenant_id,
          action_type: action_type,
          ip_address: "0.0.0.0",
          request_id: nil,
          endpoint_path: "/workers/outbox/dispatch_event",
          http_method: "JOB",
          channel: "WORKER",
          target_type: TARGET_TYPE,
          target_id: target_id,
          success: success,
          occurred_at: Time.current,
          metadata: normalize_metadata(metadata)
        )
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => log_error
        Rails.logger.error(
          "escrow_payment_instructions_action_log_write_error " \
          "outbox_event_id=#{outbox_event.id} error_class=#{log_error.class.name} " \
          "error_message=#{log_error.message}"
        )
      end

      def normalize_metadata(raw_metadata)
        case raw_metadata
        when ActionController::Parameters
          normalize_metadata(raw_metadata.to_unsafe_h)
        when Hash
          raw_metadata.each_with_object({}) do |(key, value), output|
            output[key.to_s] = normalize_metadata(value)
          end
        when Array
          raw_metadata.map { |entry| normalize_metadata(entry) }
        else
          raw_metadata
        end
      end
    end
  end
end
