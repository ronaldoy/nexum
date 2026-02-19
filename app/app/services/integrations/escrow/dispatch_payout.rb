module Integrations
  module Escrow
    class DispatchPayout
      EVENT_TYPE = "ANTICIPATION_ESCROW_PAYOUT_REQUESTED".freeze
      TARGET_TYPE = "EscrowPayout".freeze
      PAYABLE_PARTY_KINDS = %w[SUPPLIER PHYSICIAN_PF LEGAL_ENTITY_PJ].freeze

      def call(outbox_event:)
        payload = {}
        anticipation_request = nil
        settlement = nil
        recipient_party = nil
        amount = BigDecimal("0")
        provider_code = nil
        payout = nil
        payout_idempotency_key = nil

        payload = normalize_metadata(outbox_event.payload || {})
        anticipation_request_id = payload["anticipation_request_id"].to_s.presence
        settlement_id = payload["settlement_id"].to_s.presence
        ensure_source_reference_present!(anticipation_request_id:, settlement_id:)
        recipient_party_id = payload["recipient_party_id"].to_s.presence

        anticipation_request = load_anticipation_request(tenant_id: outbox_event.tenant_id, anticipation_request_id:)
        settlement = load_settlement(tenant_id: outbox_event.tenant_id, settlement_id:)

        recipient_party_id ||= anticipation_request&.requester_party_id
        recipient_party_id ||= settlement&.receivable&.beneficiary_party_id
        raise ValidationError.new(code: "recipient_party_missing", message: "recipient_party_id is required.") if recipient_party_id.blank?

        recipient_party = Party.where(tenant_id: outbox_event.tenant_id).lock.find(recipient_party_id)
        ensure_party_payable!(recipient_party)

        amount = round_money(parse_decimal(payload.fetch("amount"), field: "amount"))
        raise ValidationError.new(code: "invalid_amount", message: "amount must be greater than zero.") if amount <= 0
        ensure_excess_amount_matches_settlement!(payload:, settlement:, amount:)

        provider_code = ProviderConfig.normalize_provider(
          payload["provider"].presence || ProviderConfig.default_provider(tenant_id: outbox_event.tenant_id)
        )
        provider = ProviderRegistry.fetch(provider_code: provider_code)

        payout_idempotency_key = payload["payout_idempotency_key"].to_s.presence || outbox_event.idempotency_key.to_s.presence || "#{outbox_event.id}:escrow_payout"
        account_idempotency_key = payload["account_idempotency_key"].to_s.presence || "#{recipient_party.id}:escrow_account"

        payout = EscrowPayout.lock.find_or_initialize_by(
          tenant_id: outbox_event.tenant_id,
          idempotency_key: payout_idempotency_key
        )
        return payout if payout.persisted? && payout.status == "SENT"

        escrow_account = ensure_escrow_account!(
          tenant_id: outbox_event.tenant_id,
          party: recipient_party,
          provider: provider,
          idempotency_key: account_idempotency_key,
          metadata: payload
        )

        payout.assign_attributes(
          tenant_id: outbox_event.tenant_id,
          anticipation_request_id: anticipation_request&.id,
          receivable_payment_settlement_id: settlement&.id,
          party_id: recipient_party.id,
          escrow_account_id: escrow_account.id,
          provider: provider_code,
          status: payout.status.presence || "PENDING",
          amount: amount,
          currency: "BRL",
          requested_at: payout.requested_at || Time.current,
          metadata: merge_metadata(payout.metadata, {
            "outbox_event_id" => outbox_event.id,
            "payload" => payload
          })
        )
        payout.save! if payout.new_record? || payout.changed?

        provider_request_control_key = payload["provider_request_control_key"].to_s.presence || payout_idempotency_key
        payout_result = provider.create_payout!(
          tenant_id: outbox_event.tenant_id,
          escrow_account: escrow_account,
          recipient_party: recipient_party,
          amount: amount,
          currency: "BRL",
          idempotency_key: provider_request_control_key,
          metadata: payload.merge("provider_request_control_key" => provider_request_control_key)
        )

        persisted = persist_payout_success!(
          payout: payout,
          outbox_event: outbox_event,
          anticipation_request: anticipation_request,
          settlement: settlement,
          recipient_party: recipient_party,
          escrow_account: escrow_account,
          provider_code: provider_code,
          amount: amount,
          payout_result: payout_result,
          payload: payload
        )

        if persisted.status != "SENT"
          raise ValidationError.new(
            code: "escrow_payout_not_sent",
            message: "Escrow payout did not reach a sent state.",
            details: { status: persisted.status }
          )
        end

        create_action_log!(
          outbox_event: outbox_event,
          action_type: "ESCROW_PAYOUT_DISPATCHED",
          success: true,
          target_id: persisted.id,
          metadata: {
            "anticipation_request_id" => anticipation_request&.id,
            "settlement_id" => settlement&.id,
            "recipient_party_id" => recipient_party.id,
            "provider" => provider_code,
            "amount" => amount.to_s("F"),
            "currency" => "BRL",
            "provider_transfer_id" => persisted.provider_transfer_id,
            "idempotency_key" => persisted.idempotency_key
          }
        )

        persisted
      rescue Error => error
        persist_payout_failure!(
          payout: payout,
          outbox_event: outbox_event,
          anticipation_request: anticipation_request,
          settlement: settlement,
          recipient_party: recipient_party,
          provider_code: provider_code,
          amount: amount,
          payload: payload,
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
        raise ValidationError.new(code: "escrow_payout_conflict", message: "Escrow payout idempotency conflict.") if payout_idempotency_key.blank?

        existing = EscrowPayout.find_by!(tenant_id: outbox_event.tenant_id, idempotency_key: payout_idempotency_key)
        return existing if existing.status == "SENT"

        raise ValidationError.new(
          code: "escrow_payout_conflict",
          message: "Escrow payout idempotency conflict."
        )
      end

      private

      def ensure_escrow_account!(tenant_id:, party:, provider:, idempotency_key:, metadata:)
        account = EscrowAccount.lock.find_by(
          tenant_id: tenant_id,
          party_id: party.id,
          provider: provider.provider_code
        )

        if account.present? && account.status == "ACTIVE" && account.provider_account_id.present?
          return account
        end

        metadata_seed = provider.account_from_party_metadata(party: party)
        if metadata_seed.present?
          account = upsert_account_from_seed!(
            account: account,
            tenant_id: tenant_id,
            party: party,
            provider_code: provider.provider_code,
            seed: metadata_seed
          )
          return account if account.status == "ACTIVE" && account.provider_account_id.present?
        end

        provision_result = provider.open_escrow_account!(
          tenant_id: tenant_id,
          party: party,
          idempotency_key: idempotency_key,
          metadata: metadata
        )

        account ||= EscrowAccount.new(
          tenant_id: tenant_id,
          party_id: party.id,
          provider: provider.provider_code,
          account_type: "ESCROW"
        )

        account.status = provision_result.status.to_s.upcase
        account.provider_account_id = provision_result.provider_account_id
        account.provider_request_id = provision_result.provider_request_id
        account.last_synced_at = Time.current
        account.metadata = merge_metadata(account.metadata, provision_result.metadata)
        account.save!

        if account.status != "ACTIVE" || account.provider_account_id.blank?
          raise ValidationError.new(
            code: "escrow_account_not_active",
            message: "Escrow account is not active yet.",
            details: {
              party_id: party.id,
              provider: provider.provider_code,
              status: account.status,
              provider_request_id: account.provider_request_id
            }
          )
        end

        account
      rescue ActiveRecord::RecordNotUnique
        EscrowAccount.find_by!(tenant_id: tenant_id, party_id: party.id, provider: provider.provider_code)
      end

      def upsert_account_from_seed!(account:, tenant_id:, party:, provider_code:, seed:)
        account ||= EscrowAccount.new(
          tenant_id: tenant_id,
          party_id: party.id,
          provider: provider_code,
          account_type: "ESCROW"
        )

        account.status = seed.fetch(:status, "ACTIVE").to_s.upcase
        account.provider_account_id = seed[:provider_account_id]
        account.provider_request_id = seed[:provider_request_id]
        account.last_synced_at = Time.current
        account.metadata = merge_metadata(account.metadata, seed[:metadata])
        account.save!
        account
      end

      def persist_payout_success!(payout:, outbox_event:, anticipation_request:, settlement:, recipient_party:, escrow_account:, provider_code:, amount:, payout_result:, payload:)
        now = Time.current

        payout.assign_attributes(
          tenant_id: outbox_event.tenant_id,
          anticipation_request_id: anticipation_request&.id,
          receivable_payment_settlement_id: settlement&.id,
          party_id: recipient_party.id,
          escrow_account_id: escrow_account.id,
          provider: provider_code,
          status: payout_result.status.to_s.upcase,
          amount: amount,
          currency: "BRL",
          requested_at: payout.requested_at || now,
          processed_at: payout_result.status.to_s.upcase == "SENT" ? now : nil,
          provider_transfer_id: payout_result.provider_transfer_id,
          last_error_code: nil,
          last_error_message: nil,
          metadata: merge_metadata(payout.metadata, {
            "outbox_event_id" => outbox_event.id,
            "payload" => payload,
            "provider_result" => payout_result.metadata
          })
        )
        payout.save!
        payout
      end

      def persist_payout_failure!(payout:, outbox_event:, anticipation_request:, settlement:, recipient_party:, provider_code:, amount:, payload:, error:)
        return if payout.blank?

        payout.assign_attributes(
          tenant_id: outbox_event.tenant_id,
          anticipation_request_id: anticipation_request&.id,
          receivable_payment_settlement_id: settlement&.id,
          party_id: recipient_party&.id,
          provider: provider_code.to_s.presence || payout.provider || ProviderConfig::DEFAULT_PROVIDER,
          amount: amount.to_d.positive? ? amount : payout.amount,
          currency: "BRL",
          status: "FAILED",
          requested_at: payout.requested_at || Time.current,
          last_error_code: error.code,
          last_error_message: error.message.to_s.truncate(500),
          metadata: merge_metadata(payout.metadata, {
            "outbox_event_id" => outbox_event.id,
            "payload" => payload,
            "error_details" => error.details
          })
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
