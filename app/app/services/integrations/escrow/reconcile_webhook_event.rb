module Integrations
  module Escrow
    class ReconcileWebhookEvent
      Result = Struct.new(:status, :target_type, :target_id, :metadata, keyword_init: true)
      Target = Struct.new(:kind, :record, keyword_init: true)

      SUCCESSFUL_PAYOUT_STATUSES = %w[SENT SUCCESS SUCCESSFUL COMPLETED PROCESSING_PAYMENT].freeze
      FAILED_PAYOUT_STATUSES = %w[FAILED ERROR REJECTED CANCELED CANCELLED].freeze

      ACTIVE_ACCOUNT_STATUSES = %w[APPROVED ACTIVE OPEN OPENED].freeze
      REJECTED_ACCOUNT_STATUSES = %w[REJECTED DENIED CANCELED CANCELLED].freeze

      def initialize(tenant_id:, provider:, payload:, provider_event_id:, request_id:, request_ip:, user_agent:, endpoint_path:, http_method:)
        @tenant_id = tenant_id
        @provider = ProviderConfig.normalize_provider(provider)
        @payload = normalize_metadata(payload)
        @provider_event_id = provider_event_id.to_s
        @request_id = request_id
        @request_ip = request_ip
        @user_agent = user_agent
        @endpoint_path = endpoint_path
        @http_method = http_method
      end

      def call
        target = resolve_target
        return ignored_result if target.blank?

        process_target(target)
      end

      private

      def resolve_target
        payout = find_payout
        return Target.new(kind: :payout, record: payout) if payout

        account = find_account
        return Target.new(kind: :account, record: account) if account

        nil
      end

      def process_target(target)
        case target.kind
        when :payout
          processed_result_for_payout(target.record)
        when :account
          processed_result_for_account(target.record)
        else
          ignored_result
        end
      end

      def find_payout
        scope = payout_scope
        payout = find_payout_by_transfer_id(scope)
        return payout if payout

        find_payout_by_request_control_key(scope)
      end

      def find_account
        scope = account_scope
        account = find_account_by_provider_account_id(scope)
        return account if account

        find_account_by_provider_request_id(scope)
      end

      def reconcile_payout!(payout)
        status = raw_status
        mapped_status = map_payout_status(status)
        payout.with_lock { apply_payout_reconciliation!(payout:, status:, mapped_status:) }
        log_payout_reconciled!(payout:, status:, mapped_status:)
      end

      def reconcile_account!(account)
        status = raw_status
        mapped_status = map_account_status(status)
        account.with_lock { apply_account_reconciliation!(account:, status:, mapped_status:) }
        log_account_reconciled!(account:, status:, mapped_status:)
      end

      def payout_scope
        EscrowPayout.where(tenant_id: @tenant_id, provider: @provider)
      end

      def account_scope
        EscrowAccount.where(tenant_id: @tenant_id, provider: @provider)
      end

      def processed_result_for_payout(payout)
        reconcile_payout!(payout)
        processed_result(target_type: "EscrowPayout", target_id: payout.id)
      end

      def processed_result_for_account(account)
        reconcile_account!(account)
        processed_result(target_type: "EscrowAccount", target_id: account.id)
      end

      def processed_result(target_type:, target_id:)
        Result.new(
          status: "PROCESSED",
          target_type: target_type,
          target_id: target_id,
          metadata: { "provider_event_id" => @provider_event_id }
        )
      end

      def ignored_result
        create_action_log!(
          action_type: "ESCROW_WEBHOOK_IGNORED",
          success: true,
          metadata: provider_metadata("reason" => "resource_not_found")
        )
        Result.new(
          status: "IGNORED",
          target_type: nil,
          target_id: nil,
          metadata: {
            "provider_event_id" => @provider_event_id,
            "reason" => "resource_not_found"
          }
        )
      end

      def find_payout_by_transfer_id(scope)
        transfer_ids = payout_transfer_id_candidates
        latest_match(scope:, column: :provider_transfer_id, candidates: transfer_ids)
      end

      def find_payout_by_request_control_key(scope)
        control_keys = request_control_key_candidates
        return nil if control_keys.empty?

        payout = latest_match(scope:, column: :idempotency_key, candidates: control_keys)
        return payout if payout

        find_payout_by_payload_control_key(scope, control_keys)
      end

      def find_payout_by_payload_control_key(scope, control_keys)
        control_keys.each do |control_key|
          payout = scope
            .where("metadata -> 'payload' ->> 'provider_request_control_key' = ?", control_key)
            .order(created_at: :desc)
            .first
          return payout if payout
        end
        nil
      end

      def find_account_by_provider_account_id(scope)
        account_ids = account_id_candidates
        latest_match(scope:, column: :provider_account_id, candidates: account_ids)
      end

      def find_account_by_provider_request_id(scope)
        request_ids = account_request_id_candidates
        latest_match(scope:, column: :provider_request_id, candidates: request_ids)
      end

      def latest_match(scope:, column:, candidates:)
        return nil if candidates.empty?

        scope.where(column => candidates).order(created_at: :desc).first
      end

      def apply_payout_reconciliation!(payout:, status:, mapped_status:)
        payout.update!(payout_reconciliation_attributes(payout:, status:, mapped_status:))
      end

      def payout_reconciliation_attributes(payout:, status:, mapped_status:)
        now = Time.current
        attrs = {
          metadata: merge_metadata(payout.metadata, webhook_reconciliation_metadata(status: status, received_at: now))
        }
        transfer_id = payout_transfer_id_candidates.first
        attrs[:provider_transfer_id] = transfer_id if transfer_id.present? && payout.provider_transfer_id.blank?
        attrs.merge!(payout_status_attributes(payout:, mapped_status:, now: now))
        attrs
      end

      def payout_status_attributes(payout:, mapped_status:, now:)
        case mapped_status
        when "SENT"
          {
            status: "SENT",
            processed_at: now,
            last_error_code: nil,
            last_error_message: nil
          }
        when "FAILED"
          return {} if payout.status == "SENT"

          {
            status: "FAILED",
            processed_at: now,
            last_error_code: payout_error_code,
            last_error_message: payout_error_message
          }
        else
          {}
        end
      end

      def apply_account_reconciliation!(account:, status:, mapped_status:)
        account.update!(account_reconciliation_attributes(account:, status:, mapped_status:))
      end

      def account_reconciliation_attributes(account:, status:, mapped_status:)
        now = Time.current
        attrs = {
          last_synced_at: now,
          metadata: merge_metadata(account.metadata, webhook_reconciliation_metadata(status: status, received_at: now))
        }
        attrs.merge!(account_identifier_attributes(account))
        attrs[:status] = mapped_status if mapped_status.present?
        attrs
      end

      def account_identifier_attributes(account)
        attrs = {}
        provider_account_id = account_id_candidates.first
        provider_request_id = account_request_id_candidates.first
        attrs[:provider_account_id] = provider_account_id if provider_account_id.present? && account.provider_account_id.blank?
        attrs[:provider_request_id] = provider_request_id if provider_request_id.present? && account.provider_request_id.blank?
        attrs
      end

      def webhook_reconciliation_metadata(status:, received_at:)
        {
          "webhook_reconciliation" => {
            "provider" => @provider,
            "provider_event_id" => @provider_event_id,
            "status" => status,
            "received_at" => received_at.iso8601(6),
            "payload" => @payload
          }
        }
      end

      def log_payout_reconciled!(payout:, status:, mapped_status:)
        create_action_log!(
          action_type: "ESCROW_PAYOUT_WEBHOOK_RECONCILED",
          success: true,
          target_type: "EscrowPayout",
          target_id: payout.id,
          metadata: provider_metadata(
            "status" => status,
            "provider_transfer_id" => payout_transfer_id_candidates.first,
            "mapped_status" => mapped_status
          )
        )
      end

      def log_account_reconciled!(account:, status:, mapped_status:)
        create_action_log!(
          action_type: "ESCROW_ACCOUNT_WEBHOOK_RECONCILED",
          success: true,
          target_type: "EscrowAccount",
          target_id: account.id,
          metadata: provider_metadata(
            "status" => status,
            "mapped_status" => mapped_status
          )
        )
      end

      def provider_metadata(additional = {})
        {
          "provider" => @provider,
          "provider_event_id" => @provider_event_id
        }.merge(additional)
      end

      def payout_transfer_id_candidates
        normalized_candidates(
          @payload["end_to_end_id"],
          @payload["transaction_id"],
          @payload["pix_transfer_id"],
          @payload.dig("pix_transfer", "end_to_end_id"),
          @payload.dig("pix_transfer", "transaction_id")
        )
      end

      def request_control_key_candidates
        normalized_candidates(
          @payload["request_control_key"],
          @payload["external_reference"],
          @payload["idempotency_key"],
          @payload.dig("pix_transfer", "request_control_key")
        )
      end

      def account_id_candidates
        normalized_candidates(
          @payload["account_key"],
          @payload["provider_account_id"],
          @payload.dig("account", "account_key"),
          @payload.dig("account_info", "account_key")
        )
      end

      def account_request_id_candidates
        normalized_candidates(
          @payload["account_request_key"],
          @payload["provider_request_id"],
          @payload.dig("account", "account_request_key")
        )
      end

      def normalized_candidates(*values)
        values.map { |value| normalize_identifier(value) }.compact.uniq
      end

      def raw_status
        @payload["status"].to_s.upcase.presence ||
          @payload.dig("pix_transfer", "status").to_s.upcase.presence ||
          @payload.dig("account", "status").to_s.upcase.presence ||
          @payload.dig("account_info", "status").to_s.upcase.presence ||
          "UNKNOWN"
      end

      def map_payout_status(status)
        return "SENT" if SUCCESSFUL_PAYOUT_STATUSES.include?(status)
        return "FAILED" if FAILED_PAYOUT_STATUSES.include?(status)

        nil
      end

      def map_account_status(status)
        return "ACTIVE" if ACTIVE_ACCOUNT_STATUSES.include?(status)
        return "REJECTED" if REJECTED_ACCOUNT_STATUSES.include?(status)
        return "PENDING" if status.present?

        nil
      end

      def payout_error_code
        normalize_identifier(@payload["error_code"]) || normalize_identifier(@payload.dig("error", "code"))
      end

      def payout_error_message
        message = @payload["error_message"].presence || @payload.dig("error", "message").presence
        message.to_s.strip.truncate(500).presence
      end

      def normalize_identifier(value)
        normalized = value.to_s.strip
        normalized.presence
      end

      def create_action_log!(action_type:, success:, target_type: nil, target_id: nil, metadata: {})
        ActionIpLog.create!(action_log_attributes(
          action_type: action_type,
          success: success,
          target_type: target_type,
          target_id: target_id,
          metadata: metadata
        ))
      end

      def action_log_attributes(action_type:, success:, target_type:, target_id:, metadata:)
        {
          tenant_id: @tenant_id,
          action_type: action_type,
          ip_address: @request_ip.presence || "0.0.0.0",
          user_agent: @user_agent,
          request_id: @request_id,
          endpoint_path: @endpoint_path,
          http_method: @http_method,
          channel: "WEBHOOK",
          target_type: target_type,
          target_id: target_id,
          success: success,
          occurred_at: Time.current,
          metadata: normalize_metadata(metadata)
        }
      end

      def merge_metadata(existing, incoming)
        normalize_metadata(existing).merge(normalize_metadata(incoming))
      end

      def normalize_metadata(raw)
        case raw
        when ActionController::Parameters
          normalize_metadata(raw.to_unsafe_h)
        when Hash
          raw.each_with_object({}) do |(key, value), output|
            output[key.to_s] = normalize_metadata(value)
          end
        when Array
          raw.map { |entry| normalize_metadata(entry) }
        else
          raw
        end
      end
    end
  end
end
