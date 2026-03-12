module Integrations
  module Escrow
    class DispatchPayout
      EVENT_TYPE = "ANTICIPATION_ESCROW_PAYOUT_REQUESTED".freeze
      TARGET_TYPE = "EscrowPayout".freeze
      PAYABLE_PARTY_KINDS = %w[SUPPLIER PHYSICIAN_PF LEGAL_ENTITY_PJ].freeze
      PENDING_RETRY_ERROR_CODES = %w[starkbank_insufficient_dispatch_budget].freeze
      DispatchInputs = Struct.new(
        :payload,
        :source,
        :source_party,
        :recipient_party,
        :payout_model,
        :amount,
        :provider_code,
        :provider,
        :payout_idempotency_key,
        :account_idempotency_key,
        :provider_request_control_key,
        keyword_init: true
      )

      def call(outbox_event:)
        inputs = nil
        payout = nil

        inputs = build_dispatch_inputs(outbox_event)

        payout = find_or_initialize_payout(
          tenant_id: outbox_event.tenant_id,
          payout_idempotency_key: inputs.payout_idempotency_key
        )
        return payout if payout_dispatched?(payout)

        dispatch_payout!(
          outbox_event: outbox_event,
          payout: payout,
          inputs: inputs
        )
      rescue Error => error
        persist_payout_failure!(
          payout: payout,
          outbox_event: outbox_event,
          inputs: inputs,
          error: error
        )
        raise
      rescue KeyError => error
        raise ValidationError.new(
          code: "escrow_payload_invalid",
          message: "Escrow payout payload is missing required fields.",
          details: { missing_key: error.key }
        )
      rescue ActiveRecord::RecordNotUnique
        resolve_payout_conflict!(
          tenant_id: outbox_event.tenant_id,
          payout_idempotency_key: inputs&.payout_idempotency_key
        )
      end

      private

      def dispatch_payout!(outbox_event:, payout:, inputs:)
        escrow_account = EnsureEscrowAccount.new.call(
          tenant_id: outbox_event.tenant_id,
          party: inputs.source_party,
          provider: inputs.provider,
          idempotency_key: inputs.account_idempotency_key,
          metadata: inputs.payload
        )
        persist_pending_payout!(
          payout: payout,
          outbox_event: outbox_event,
          inputs: inputs,
          escrow_account: escrow_account,
        )

        payout_result = inputs.provider.create_payout!(
          tenant_id: outbox_event.tenant_id,
          escrow_account: escrow_account,
          recipient_party: inputs.recipient_party,
          amount: inputs.amount,
          currency: "BRL",
          idempotency_key: inputs.provider_request_control_key,
          metadata: inputs.payload.merge(
            "provider_request_control_key" => inputs.provider_request_control_key
          )
        )

        persisted = persist_payout_success!(
          payout: payout,
          outbox_event: outbox_event,
          inputs: inputs,
          escrow_account: escrow_account,
          payout_result: payout_result,
        )

        ensure_payout_dispatched!(persisted)
        schedule_status_sync!(payout: persisted) if persisted.status == "PROCESSING"
        log_dispatch_success!(
          outbox_event: outbox_event,
          payout: persisted,
          inputs: inputs
        )

        persisted
      end

      def build_dispatch_inputs(outbox_event)
        payload = normalize_metadata(outbox_event.payload || {})
        source = resolve_source_records(tenant_id: outbox_event.tenant_id, payload: payload)
        routing = resolve_payout_routing(
          tenant_id: outbox_event.tenant_id,
          payload: payload,
          anticipation_request: source[:anticipation_request],
          settlement: source[:settlement]
        )
        recipient_party = routing.recipient_party
        ensure_recipient_party_present!(recipient_party)
        ensure_party_payable!(recipient_party)
        amount = resolve_amount!(payload)
        ensure_excess_amount_matches_settlement!(payload:, settlement: source[:settlement], amount:)

        provider_context = resolve_provider_context(tenant_id: outbox_event.tenant_id, payload: payload)
        payout_idempotency_key = resolve_payout_idempotency_key(outbox_event:, payload:)
        account_idempotency_key = resolve_account_idempotency_key(payload:, source_party: routing.source_party)

        DispatchInputs.new(
          payload: payload.merge("distribution_model" => routing.distribution_metadata),
          source: source,
          source_party: routing.source_party,
          recipient_party: recipient_party,
          payout_model: routing.payout_model,
          amount: amount,
          provider_code: provider_context.fetch(:provider_code),
          provider: provider_context.fetch(:provider),
          payout_idempotency_key: payout_idempotency_key,
          account_idempotency_key: account_idempotency_key,
          provider_request_control_key: provider_request_control_key(
            payload: payload,
            payout_idempotency_key: payout_idempotency_key
          )
        )
      end

      def resolve_source_records(tenant_id:, payload:)
        anticipation_request_id = payload["anticipation_request_id"].to_s.presence
        settlement_id = payload["settlement_id"].to_s.presence
        ensure_source_reference_present!(anticipation_request_id:, settlement_id:)

        {
          anticipation_request: load_anticipation_request(tenant_id: tenant_id, anticipation_request_id: anticipation_request_id),
          settlement: load_settlement(tenant_id: tenant_id, settlement_id: settlement_id)
        }
      end

      def resolve_payout_routing(tenant_id:, payload:, anticipation_request:, settlement:)
        routing = PayoutRouting.new(tenant_id: tenant_id).call(
          payload: payload,
          anticipation_request: anticipation_request,
          settlement: settlement
        )
        ensure_source_party_present!(routing.source_party)
        routing
      end

      def resolve_amount!(payload)
        amount = round_money(parse_decimal(payload.fetch("amount"), field: "amount"))
        return amount if amount.positive?

        raise ValidationError.new(code: "invalid_amount", message: "amount must be greater than zero.")
      end

      def resolve_provider_context(tenant_id:, payload:)
        provider_code = ProviderConfig.normalize_provider(
          payload["provider"].presence || ProviderConfig.default_provider(tenant_id: tenant_id),
          tenant_id: tenant_id
        )
        {
          provider_code: provider_code,
          provider: ProviderRegistry.fetch(provider_code: provider_code, tenant_id: tenant_id)
        }
      end

      def resolve_payout_idempotency_key(outbox_event:, payload:)
        payload["payout_idempotency_key"].to_s.presence || outbox_event.idempotency_key.to_s.presence || "#{outbox_event.id}:escrow_payout"
      end

      def resolve_account_idempotency_key(payload:, source_party:)
        payload["account_idempotency_key"].to_s.presence || "#{source_party.id}:escrow_account"
      end

      def find_or_initialize_payout(tenant_id:, payout_idempotency_key:)
        EscrowPayout.lock.find_or_initialize_by(
          tenant_id: tenant_id,
          idempotency_key: payout_idempotency_key
        )
      end

      def payout_dispatched?(payout)
        payout.persisted? && payout.status.in?(%w[PROCESSING SENT])
      end

      def persist_pending_payout!(payout:, outbox_event:, inputs:, escrow_account:)
        payout.assign_attributes(
          source_reference_attributes(
            anticipation_request: inputs.source[:anticipation_request],
            settlement: inputs.source[:settlement]
          ).merge(
            tenant_id: outbox_event.tenant_id,
            party_id: inputs.recipient_party.id,
            escrow_account_id: escrow_account.id,
            provider: inputs.provider_code,
            status: payout.status.presence || "PENDING",
            amount: inputs.amount,
            currency: "BRL",
            requested_at: payout.requested_at || Time.current,
            metadata: merged_payout_metadata(
              existing_metadata: payout.metadata,
              outbox_event: outbox_event,
              payload: inputs.payload
            )
          )
        )
        payout.save! if payout.new_record? || payout.changed?
      end

      def provider_request_control_key(payload:, payout_idempotency_key:)
        payload["provider_request_control_key"].to_s.presence || payout_idempotency_key
      end

      def ensure_payout_dispatched!(payout)
        return if payout.status.in?(%w[PROCESSING SENT])

        raise ValidationError.new(
          code: "escrow_payout_not_sent",
          message: "Escrow payout did not reach a dispatched state.",
          details: { status: payout.status }
        )
      end

      def log_dispatch_success!(outbox_event:, payout:, inputs:)
        create_action_log!(
          outbox_event: outbox_event,
          action_type: "ESCROW_PAYOUT_DISPATCHED",
          success: true,
          target_id: payout.id,
          metadata: {
            "anticipation_request_id" => inputs.source[:anticipation_request]&.id,
            "settlement_id" => inputs.source[:settlement]&.id,
            "source_party_id" => inputs.source_party.id,
            "recipient_party_id" => inputs.recipient_party.id,
            "payout_model" => inputs.payout_model,
            "provider" => inputs.provider_code,
            "amount" => inputs.amount.to_s("F"),
            "currency" => "BRL",
            "provider_transfer_id" => payout.provider_transfer_id,
            "provider_status" => payout.provider_status,
            "provider_fee_amount" => payout.provider_fee_amount.to_d.to_s("F"),
            "batch_id" => payout.escrow_payout_batch_id,
            "idempotency_key" => payout.idempotency_key
          }
        )
      end

      def resolve_payout_conflict!(tenant_id:, payout_idempotency_key:)
        raise ValidationError.new(code: "escrow_payout_conflict", message: "Escrow payout idempotency conflict.") if payout_idempotency_key.blank?

        existing = EscrowPayout.find_by!(tenant_id: tenant_id, idempotency_key: payout_idempotency_key)
        return existing if existing.status.in?(%w[PROCESSING SENT])

        raise ValidationError.new(
          code: "escrow_payout_conflict",
          message: "Escrow payout idempotency conflict."
        )
      end

      def persist_payout_success!(payout:, outbox_event:, inputs:, escrow_account:, payout_result:)
        now = Time.current
        normalized_status = payout_result.status.to_s.upcase

        payout.assign_attributes(
          source_reference_attributes(
            anticipation_request: inputs.source[:anticipation_request],
            settlement: inputs.source[:settlement]
          ).merge(
            tenant_id: outbox_event.tenant_id,
            party_id: inputs.recipient_party.id,
            escrow_account_id: escrow_account.id,
            escrow_payout_batch_id: payout_result.batch_id,
            provider: inputs.provider_code,
            status: normalized_status,
            amount: inputs.amount,
            currency: "BRL",
            requested_at: payout.requested_at || now,
            processed_at: normalized_status.in?(%w[SENT FAILED]) ? now : payout.processed_at,
            provider_transfer_id: payout_result.provider_transfer_id,
            provider_status: payout_result.provider_status.to_s.presence,
            provider_fee_amount: payout_result.provider_fee_amount.to_d,
            provider_fee_currency: payout_result.provider_fee_currency.to_s.presence || "BRL",
            provider_source_account_id: payout_result.provider_source_account_id,
            provider_destination_account_id: payout_result.provider_destination_account_id,
            provider_end_to_end_id: payout_result.provider_end_to_end_id,
            confirmed_at: payout_result.confirmed_at,
            last_error_code: nil,
            last_error_message: nil,
            metadata: merged_payout_metadata(
              existing_metadata: payout.metadata,
              outbox_event: outbox_event,
              payload: inputs.payload,
              extra: { "provider_result" => payout_result.metadata }
            )
          )
        )
        payout.save!
        payout
      end

      def persist_payout_failure!(payout:, outbox_event:, inputs:, error:)
        return if payout.blank?

        source = inputs&.source || {}
        recipient_party = inputs&.recipient_party
        source_party = inputs&.source_party
        provider_code = inputs&.provider_code
        amount = inputs&.amount || BigDecimal("0")
        payload = inputs&.payload || {}
        pending_retry = retryable_pending_failure?(error)

        payout.assign_attributes(
          source_reference_attributes(
            anticipation_request: source[:anticipation_request],
            settlement: source[:settlement]
          ).merge(
            tenant_id: outbox_event.tenant_id,
            party_id: recipient_party&.id,
            escrow_account_id: payout.escrow_account_id || active_escrow_account_id_for(tenant_id: outbox_event.tenant_id, source_party: source_party, provider_code: provider_code),
            provider: provider_code.to_s.presence || payout.provider || ProviderConfig::DEFAULT_PROVIDER,
            amount: amount.to_d.positive? ? amount : payout.amount,
            currency: "BRL",
            status: pending_retry ? "PENDING" : "FAILED",
            requested_at: payout.requested_at || Time.current,
            last_error_code: error.code,
            last_error_message: error.message.to_s.truncate(500),
            metadata: merged_payout_metadata(
              existing_metadata: payout.metadata,
              outbox_event: outbox_event,
              payload: payload,
              extra: { "error_details" => error.details }
            )
          )
        )
        payout.save!

        create_action_log!(
          outbox_event: outbox_event,
          action_type: "ESCROW_PAYOUT_DISPATCH_FAILED",
          success: false,
          target_id: payout.id,
          metadata: {
            "idempotency_key" => payout.idempotency_key,
            "provider" => payout.provider,
            "error_code" => error.code,
            "error_message" => error.message
          }
        )
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => log_error
        Rails.logger.error(
          "escrow_payout_failure_persist_error " \
          "error_class=#{log_error.class.name} error_message=#{log_error.message} " \
          "original_error_code=#{error.code}"
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

      def source_reference_attributes(anticipation_request:, settlement:)
        {
          anticipation_request_id: anticipation_request&.id,
          receivable_payment_settlement_id: settlement&.id
        }
      end

      def merged_payout_metadata(existing_metadata:, outbox_event:, payload:, extra: {})
        merge_metadata(existing_metadata, {
          "outbox_event_id" => outbox_event.id,
          "payload" => payload
        }.merge(extra))
      end

      def retryable_pending_failure?(error)
        PENDING_RETRY_ERROR_CODES.include?(error.code.to_s)
      end

      def schedule_status_sync!(payout:)
        Integrations::Escrow::SyncPayoutStatusJob
          .set(wait: 20.seconds)
          .perform_later(tenant_id: payout.tenant_id, payout_id: payout.id)
      end

      def active_escrow_account_id_for(tenant_id:, source_party:, provider_code:)
        return nil if source_party.blank? || provider_code.blank?

        EscrowAccount.find_by(
          tenant_id: tenant_id,
          party_id: source_party.id,
          provider: provider_code
        )&.id
      end

      def ensure_source_party_present!(source_party)
        return if source_party.present?

        raise ValidationError.new(code: "source_party_missing", message: "source_party_id is required.")
      end

      def ensure_recipient_party_present!(recipient_party)
        return if recipient_party.present?

        raise ValidationError.new(code: "recipient_party_missing", message: "recipient_party_id is required.")
      end

      def ensure_party_payable!(party)
        return if PAYABLE_PARTY_KINDS.include?(party.kind)

        raise ValidationError.new(
          code: "escrow_party_kind_not_supported",
          message: "Escrow payouts are only supported for physicians and suppliers.",
          details: { party_id: party.id, kind: party.kind }
        )
      end

      def ensure_source_reference_present!(anticipation_request_id:, settlement_id:)
        return if anticipation_request_id.present? || settlement_id.present?

        raise ValidationError.new(
          code: "escrow_payload_source_missing",
          message: "Escrow payload must include anticipation_request_id or settlement_id."
        )
      end

      def load_anticipation_request(tenant_id:, anticipation_request_id:)
        return nil if anticipation_request_id.blank?

        AnticipationRequest.where(tenant_id: tenant_id).lock.find(anticipation_request_id)
      end

      def load_settlement(tenant_id:, settlement_id:)
        return nil if settlement_id.blank?

        ReceivablePaymentSettlement.where(tenant_id: tenant_id).lock.find(settlement_id)
      end

      def ensure_excess_amount_matches_settlement!(payload:, settlement:, amount:)
        return unless payload["payout_kind"].to_s.upcase == "EXCESS"
        return if settlement.blank?

        expected_amount = round_money(settlement.beneficiary_amount.to_d)
        return if amount == expected_amount

        raise ValidationError.new(
          code: "escrow_excess_amount_mismatch",
          message: "Excess payout amount must match settlement beneficiary amount.",
          details: {
            settlement_id: settlement.id,
            expected_amount: expected_amount.to_s("F"),
            provided_amount: amount.to_s("F")
          }
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
