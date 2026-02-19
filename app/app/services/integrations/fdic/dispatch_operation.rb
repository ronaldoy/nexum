require "digest"

module Integrations
  module Fdic
    class DispatchOperation
      TARGET_TYPE = "FdicOperation".freeze
      FUNDING_EVENT_TYPE = "ANTICIPATION_FIDC_FUNDING_REQUESTED".freeze
      SETTLEMENT_EVENT_TYPE = "RECEIVABLE_FIDC_SETTLEMENT_REPORTED".freeze
      PAYLOAD_HASH_METADATA_KEY = "_payload_hash".freeze

      OPERATION_TYPES_BY_EVENT = {
        FUNDING_EVENT_TYPE => "FUNDING_REQUEST",
        SETTLEMENT_EVENT_TYPE => "SETTLEMENT_REPORT"
      }.freeze

      SENT_STATUSES = %w[SENT SUCCESS ACCEPTED COMPLETED].freeze

      def call(outbox_event:)
        operation_type = OPERATION_TYPES_BY_EVENT[outbox_event.event_type]
        if operation_type.blank?
          raise ValidationError.new(
            code: "fdic_event_type_not_supported",
            message: "FDIC dispatcher does not support event type #{outbox_event.event_type.inspect}."
          )
        end

        payload = normalize_metadata(outbox_event.payload || {})
        provider_code = ProviderConfig.normalize_provider(
          payload["provider"].presence || ProviderConfig.default_provider(tenant_id: outbox_event.tenant_id)
        )
        provider = ProviderRegistry.fetch(provider_code: provider_code)

        operation_idempotency_key = payload["operation_idempotency_key"].to_s.presence ||
          outbox_event.idempotency_key.to_s.presence ||
          "#{outbox_event.id}:fdic_operation"

        amount = round_money(parse_decimal(payload.fetch("amount"), field: "amount"))
        raise ValidationError.new(code: "invalid_amount", message: "amount must be greater than zero.") if amount <= 0

        currency = payload.fetch("currency", "BRL").to_s.upcase
        if currency != "BRL"
          raise ValidationError.new(code: "invalid_currency", message: "FDIC operation currency must be BRL.")
        end

        payload_hash = payload_hash_for(
          operation_type: operation_type,
          payload: payload,
          amount: amount,
          currency: currency,
          provider: provider_code
        )

        source = resolve_source!(
          tenant_id: outbox_event.tenant_id,
          operation_type: operation_type,
          payload: payload
        )

        operation = FdicOperation.lock.find_or_initialize_by(
          tenant_id: outbox_event.tenant_id,
          idempotency_key: operation_idempotency_key
        )

        if operation.persisted?
          ensure_payload_compatibility!(operation: operation, payload_hash: payload_hash)
          return operation if operation.sent?
        end

        operation.assign_attributes(
          tenant_id: outbox_event.tenant_id,
          anticipation_request_id: source[:anticipation_request]&.id,
          receivable_payment_settlement_id: source[:settlement]&.id,
          provider: provider_code,
          operation_type: operation_type,
          status: "PENDING",
          amount: amount,
          currency: currency,
          requested_at: operation.requested_at || Time.current,
          metadata: merge_metadata(operation.metadata, {
            PAYLOAD_HASH_METADATA_KEY => payload_hash,
            "outbox_event_id" => outbox_event.id,
            "payload" => payload
          })
        )
        operation.save! if operation.new_record? || operation.changed?

        provider_request_control_key = payload["provider_request_control_key"].to_s.presence || operation_idempotency_key
        provider_result = dispatch_provider!(
          provider: provider,
          operation_type: operation_type,
          tenant_id: outbox_event.tenant_id,
          source: source,
          payload: payload,
          idempotency_key: provider_request_control_key
        )

        persisted = persist_success!(
          operation: operation,
          provider_result: provider_result,
          payload: payload
        )
        if persisted.status != "SENT"
          raise ValidationError.new(
            code: "fdic_operation_not_sent",
            message: "FDIC operation did not reach a sent state.",
            details: { status: persisted.status }
          )
        end

        create_action_log!(
          outbox_event: outbox_event,
          action_type: "FDIC_OPERATION_DISPATCHED",
          success: true,
          target_id: persisted.id,
          metadata: {
            "operation_type" => persisted.operation_type,
            "provider" => persisted.provider,
            "provider_reference" => persisted.provider_reference,
            "idempotency_key" => persisted.idempotency_key,
            "amount" => persisted.amount.to_d.to_s("F"),
            "currency" => persisted.currency
          }
        )

        persisted
      rescue Error => error
        persist_failure!(operation: operation, outbox_event: outbox_event, payload: payload, error: error)
        raise
      rescue KeyError => error
        raise ValidationError.new(
          code: "fdic_payload_invalid",
          message: "FDIC payload is missing required fields.",
          details: { missing_key: error.key }
        )
      rescue ActiveRecord::RecordNotUnique
        existing = FdicOperation.find_by!(tenant_id: outbox_event.tenant_id, idempotency_key: operation_idempotency_key)
        return existing if existing.sent?

        raise ValidationError.new(
          code: "fdic_operation_conflict",
          message: "FDIC operation idempotency conflict."
        )
      end

      private

      def resolve_source!(tenant_id:, operation_type:, payload:)
        case operation_type
        when "FUNDING_REQUEST"
          anticipation_request_id = payload["anticipation_request_id"].to_s.presence
          if anticipation_request_id.blank?
            raise ValidationError.new(
              code: "fdic_payload_source_missing",
              message: "FUNDING_REQUEST payload must include anticipation_request_id."
            )
          end

          anticipation_request = AnticipationRequest.where(tenant_id: tenant_id).lock.find(anticipation_request_id)
          { anticipation_request: anticipation_request, settlement: nil }
        when "SETTLEMENT_REPORT"
          settlement_id = payload["settlement_id"].to_s.presence || payload["receivable_payment_settlement_id"].to_s.presence
          if settlement_id.blank?
            raise ValidationError.new(
              code: "fdic_payload_source_missing",
              message: "SETTLEMENT_REPORT payload must include settlement_id."
            )
          end

          settlement = ReceivablePaymentSettlement.where(tenant_id: tenant_id).lock.find(settlement_id)
          { anticipation_request: nil, settlement: settlement }
        else
          raise ValidationError.new(
            code: "fdic_operation_type_invalid",
            message: "FDIC operation type is invalid."
          )
        end
      end

      def dispatch_provider!(provider:, operation_type:, tenant_id:, source:, payload:, idempotency_key:)
        case operation_type
        when "FUNDING_REQUEST"
          provider.request_funding!(
            tenant_id: tenant_id,
            anticipation_request: source.fetch(:anticipation_request),
            payload: payload,
            idempotency_key: idempotency_key
          )
        when "SETTLEMENT_REPORT"
          provider.report_settlement!(
            tenant_id: tenant_id,
            settlement: source.fetch(:settlement),
            payload: payload,
            idempotency_key: idempotency_key
          )
        else
          raise ValidationError.new(
            code: "fdic_operation_type_invalid",
            message: "FDIC operation type is invalid."
          )
        end
      end

      def persist_success!(operation:, provider_result:, payload:)
        status = map_provider_status(provider_result.status)
        now = Time.current

        operation.assign_attributes(
          status: status,
          provider_reference: provider_result.provider_reference.to_s.presence || operation.provider_reference,
          processed_at: status == "SENT" ? now : nil,
          last_error_code: nil,
          last_error_message: nil,
          metadata: merge_metadata(operation.metadata, {
            "payload" => payload,
            "provider_result" => normalize_metadata(provider_result.metadata)
          })
        )
        operation.save!
        operation
      end

      def persist_failure!(operation:, outbox_event:, payload:, error:)
        return if operation.blank?

        operation.assign_attributes(
          status: "FAILED",
          processed_at: nil,
          last_error_code: error.code,
          last_error_message: error.message.to_s.truncate(500),
          metadata: merge_metadata(operation.metadata, {
            "outbox_event_id" => outbox_event.id,
            "payload" => payload,
            "error_details" => error.details
          })
        )
        operation.save!

        create_action_log!(
          outbox_event: outbox_event,
          action_type: "FDIC_OPERATION_DISPATCH_FAILED",
          success: false,
          target_id: operation.id,
          metadata: {
            "operation_type" => operation.operation_type,
            "provider" => operation.provider,
            "idempotency_key" => operation.idempotency_key,
            "error_code" => error.code,
            "error_message" => error.message
          }
        )
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => log_error
        Rails.logger.error(
          "fdic_operation_failure_persist_error " \
          "error_class=#{log_error.class.name} error_message=#{log_error.message} " \
          "original_error_code=#{error.code}"
        )
      end

      def ensure_payload_compatibility!(operation:, payload_hash:)
        stored_hash = operation.metadata&.[](PAYLOAD_HASH_METADATA_KEY).to_s
        return if stored_hash.blank? || stored_hash == payload_hash

        raise ValidationError.new(
          code: "fdic_operation_idempotency_conflict",
          message: "FDIC operation idempotency key was already used with a different payload."
        )
      end

      def parse_decimal(raw_value, field:)
        value = BigDecimal(raw_value.to_s)
        return value if value.finite?

        raise ValidationError.new(code: "invalid_#{field}", message: "#{field} is invalid.")
      rescue ArgumentError
        raise ValidationError.new(code: "invalid_#{field}", message: "#{field} is invalid.")
      end

      def round_money(value)
        FinancialRounding.money(value)
      end

      def payload_hash_for(operation_type:, payload:, amount:, currency:, provider:)
        Digest::SHA256.hexdigest(
          CanonicalJson.encode(
            operation_type: operation_type,
            amount: amount.to_d.to_s("F"),
            currency: currency,
            provider: provider,
            payload: payload
          )
        )
      end

      def map_provider_status(raw_status)
        normalized = raw_status.to_s.strip.upcase
        return "SENT" if SENT_STATUSES.include?(normalized)

        "FAILED"
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

      def merge_metadata(existing, incoming)
        normalize_metadata(existing).merge(normalize_metadata(incoming))
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
