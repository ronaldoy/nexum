module Integrations
  module HospitalApi
    class DispatchPaymentInstructions
      TARGET_TYPE = "Receivable".freeze

      DispatchInputs = Struct.new(
        :payload,
        :receivable,
        :receivable_allocation,
        :hospital_party,
        :idempotency_key,
        keyword_init: true
      )

      def call(outbox_event:)
        inputs = build_dispatch_inputs(outbox_event)
        response = dispatch!(outbox_event:, inputs:)

        log_dispatch_success!(
          outbox_event: outbox_event,
          inputs: inputs,
          response: response
        )

        response
      rescue Error, Integrations::Escrow::Error => error
        log_dispatch_failure!(outbox_event: outbox_event, inputs: inputs, error: error) if outbox_event.present?
        raise
      end

      private

      def dispatch!(outbox_event:, inputs:)
        payment_instruction_result = Integrations::Escrow::EnsurePaymentInstructions.new.call(
          tenant_id: outbox_event.tenant_id,
          receivable: inputs.receivable,
          receivable_allocation: inputs.receivable_allocation,
          idempotency_key: inputs.payload["payment_instruction_idempotency_key"].to_s.presence,
          requested_provider_code: inputs.payload["provider"].to_s.presence,
          allow_provisioning: true,
          allow_provider_fetch: true,
          persist_payment_instructions: true
        )

        client = Client.new(
          base_url: Configuration.base_url_for(tenant_id: outbox_event.tenant_id, hospital_party_id: inputs.hospital_party.id),
          bearer_token: Configuration.bearer_token_for(tenant_id: outbox_event.tenant_id, hospital_party_id: inputs.hospital_party.id),
          open_timeout: Configuration.open_timeout_seconds_for(tenant_id: outbox_event.tenant_id, hospital_party_id: inputs.hospital_party.id),
          read_timeout: Configuration.read_timeout_seconds_for(tenant_id: outbox_event.tenant_id, hospital_party_id: inputs.hospital_party.id)
        )

        client.upsert_payment_instructions!(
          path: Configuration.payment_instructions_path_for(tenant_id: outbox_event.tenant_id, hospital_party_id: inputs.hospital_party.id),
          idempotency_key: inputs.idempotency_key,
          body: request_body(
            outbox_event: outbox_event,
            inputs: inputs,
            payment_instruction_result: payment_instruction_result
          )
        )
      end

      def build_dispatch_inputs(outbox_event)
        payload = normalize_metadata(outbox_event.payload || {})
        receivable = Receivable.where(tenant_id: outbox_event.tenant_id).find(payload.fetch("receivable_id"))
        allocation = ReceivableAllocation.where(
          tenant_id: outbox_event.tenant_id,
          receivable_id: receivable.id
        ).find(payload.fetch("receivable_allocation_id"))
        hospital_party = Party.where(tenant_id: outbox_event.tenant_id).find(payload.fetch("hospital_party_id"))

        unless receivable.debtor_party_id == hospital_party.id && hospital_party.kind == "HOSPITAL"
          raise ValidationError.new(
            code: "hospital_api_invalid_hospital_party",
            message: "Hospital API sync payload does not match the receivable hospital.",
            details: {
              receivable_id: receivable.id,
              hospital_party_id: hospital_party.id
            }
          )
        end

        DispatchInputs.new(
          payload: payload,
          receivable: receivable,
          receivable_allocation: allocation,
          hospital_party: hospital_party,
          idempotency_key: payload["hospital_sync_idempotency_key"].to_s.presence || outbox_event.idempotency_key.to_s.presence || "#{outbox_event.id}:hospital_payment_instructions"
        )
      rescue KeyError => error
        raise ValidationError.new(
          code: "hospital_api_payload_invalid",
          message: "Hospital API payload is missing required fields.",
          details: { missing_key: error.key }
        )
      end

      def request_body(outbox_event:, inputs:, payment_instruction_result:)
        {
          "operation" => "receivable_payment_instructions_upsert",
          "request_control_key" => inputs.idempotency_key,
          "tenant_id" => outbox_event.tenant_id,
          "receivable" => {
            "id" => inputs.receivable.id,
            "external_reference" => inputs.receivable.external_reference,
            "due_at" => inputs.receivable.due_at&.iso8601,
            "cutoff_at" => inputs.receivable.cutoff_at&.iso8601
          },
          "receivable_allocation" => {
            "id" => inputs.receivable_allocation.id,
            "sequence" => inputs.receivable_allocation.sequence,
            "gross_amount" => inputs.receivable_allocation.gross_amount.to_d.to_s("F")
          },
          "hospital" => {
            "party_id" => inputs.hospital_party.id,
            "legal_name" => inputs.hospital_party.legal_name,
            "document_number" => inputs.hospital_party.document_number
          },
          "operational_party" => {
            "party_id" => payment_instruction_result.operational_party.id,
            "kind" => payment_instruction_result.operational_party.kind,
            "legal_name" => payment_instruction_result.operational_party.legal_name,
            "document_number" => payment_instruction_result.operational_party.document_number
          },
          "payment_instructions" => payment_instruction_result.payment_instructions
        }
      end

      def log_dispatch_success!(outbox_event:, inputs:, response:)
        create_action_log!(
          outbox_event: outbox_event,
          action_type: "HOSPITAL_PAYMENT_INSTRUCTIONS_SYNCED",
          success: true,
          target_id: inputs.receivable.id,
          metadata: {
            "receivable_allocation_id" => inputs.receivable_allocation.id,
            "hospital_party_id" => inputs.hospital_party.id,
            "idempotency_key" => inputs.idempotency_key,
            "http_status" => response["http_status"]
          }
        )
      end

      def log_dispatch_failure!(outbox_event:, inputs:, error:)
        create_action_log!(
          outbox_event: outbox_event,
          action_type: "HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_FAILED",
          success: false,
          target_id: inputs&.receivable&.id || outbox_event.aggregate_id,
          metadata: {
            "receivable_allocation_id" => inputs&.receivable_allocation&.id,
            "hospital_party_id" => inputs&.hospital_party&.id,
            "idempotency_key" => inputs&.idempotency_key,
            "error_code" => error.code,
            "error_message" => error.message
          }
        )
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => log_error
        Rails.logger.error(
          "hospital_payment_instructions_action_log_write_error " \
          "outbox_event_id=#{outbox_event.id} error_class=#{log_error.class.name} " \
          "error_message=#{log_error.message}"
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
