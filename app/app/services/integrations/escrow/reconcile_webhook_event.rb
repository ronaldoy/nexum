module Integrations
  module Escrow
    class ReconcileWebhookEvent
      Result = Struct.new(:status, :target_type, :target_id, :metadata, keyword_init: true)

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
        payout = find_payout
        if payout
          reconcile_payout!(payout)
          return Result.new(
            status: "PROCESSED",
            target_type: "EscrowPayout",
            target_id: payout.id,
            metadata: { "provider_event_id" => @provider_event_id }
          )
        end

        account = find_account
        if account
          reconcile_account!(account)
          return Result.new(
            status: "PROCESSED",
            target_type: "EscrowAccount",
            target_id: account.id,
            metadata: { "provider_event_id" => @provider_event_id }
          )
        end

        create_action_log!(
          action_type: "ESCROW_WEBHOOK_IGNORED",
          success: true,
          metadata: {
            "provider" => @provider,
            "provider_event_id" => @provider_event_id,
            "reason" => "resource_not_found"
          }
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

      private

      def find_payout
        scope = EscrowPayout.where(tenant_id: @tenant_id, provider: @provider)

        transfer_ids = payout_transfer_id_candidates
        payout = scope.where(provider_transfer_id: transfer_ids).order(created_at: :desc).first if transfer_ids.any?
        return payout if payout

        control_keys = request_control_key_candidates
        return nil if control_keys.empty?

        payout = scope.where(idempotency_key: control_keys).order(created_at: :desc).first
        return payout if payout

        control_keys.each do |control_key|
          payout = scope
            .where("metadata -> 'payload' ->> 'provider_request_control_key' = ?", control_key)
            .order(created_at: :desc)
            .first
          return payout if payout
        end

        nil
      end

      def find_account
        scope = EscrowAccount.where(tenant_id: @tenant_id, provider: @provider)

        account_ids = account_id_candidates
        account = scope.where(provider_account_id: account_ids).order(created_at: :desc).first if account_ids.any?
        return account if account

        request_ids = account_request_id_candidates
        return nil if request_ids.empty?

        scope.where(provider_request_id: request_ids).order(created_at: :desc).first
      end

      def reconcile_payout!(payout)
        payout.with_lock do
          mapped_status = map_payout_status(raw_status)
          transfer_id = payout_transfer_id_candidates.first
          now = Time.current

          attrs = {
            metadata: merge_metadata(payout.metadata, {
              "webhook_reconciliation" => {
                "provider" => @provider,
                "provider_event_id" => @provider_event_id,
                "status" => raw_status,
                "received_at" => now.iso8601(6),
                "payload" => @payload
              }
            })
          }

          attrs[:provider_transfer_id] = transfer_id if transfer_id.present? && payout.provider_transfer_id.blank?

          case mapped_status
          when "SENT"
            attrs[:status] = "SENT"
            attrs[:processed_at] = now
            attrs[:last_error_code] = nil
            attrs[:last_error_message] = nil
          when "FAILED"
            unless payout.status == "SENT"
              attrs[:status] = "FAILED"
              attrs[:processed_at] = now
              attrs[:last_error_code] = payout_error_code
              attrs[:last_error_message] = payout_error_message
            end
          end

          payout.update!(attrs)
        end

        create_action_log!(
          action_type: "ESCROW_PAYOUT_WEBHOOK_RECONCILED",
          success: true,
          target_type: "EscrowPayout",
          target_id: payout.id,
          metadata: {
            "provider" => @provider,
            "provider_event_id" => @provider_event_id,
            "status" => raw_status,
            "provider_transfer_id" => payout_transfer_id_candidates.first,
            "mapped_status" => map_payout_status(raw_status)
          }
        )
      end

      def reconcile_account!(account)
        account.with_lock do
          mapped_status = map_account_status(raw_status)
          now = Time.current

          attrs = {
            last_synced_at: now,
            metadata: merge_metadata(account.metadata, {
              "webhook_reconciliation" => {
                "provider" => @provider,
                "provider_event_id" => @provider_event_id,
                "status" => raw_status,
                "received_at" => now.iso8601(6),
                "payload" => @payload
              }
            })
          }

          provider_account_id = account_id_candidates.first
          provider_request_id = account_request_id_candidates.first
          attrs[:provider_account_id] = provider_account_id if provider_account_id.present? && account.provider_account_id.blank?
          attrs[:provider_request_id] = provider_request_id if provider_request_id.present? && account.provider_request_id.blank?

          attrs[:status] = mapped_status if mapped_status.present?

          account.update!(attrs)
        end

        create_action_log!(
          action_type: "ESCROW_ACCOUNT_WEBHOOK_RECONCILED",
          success: true,
          target_type: "EscrowAccount",
          target_id: account.id,
          metadata: {
            "provider" => @provider,
            "provider_event_id" => @provider_event_id,
            "status" => raw_status,
            "mapped_status" => map_account_status(raw_status)
          }
        )
      end

      def payout_transfer_id_candidates
        [
          @payload["end_to_end_id"],
          @payload["transaction_id"],
          @payload["pix_transfer_id"],
          @payload.dig("pix_transfer", "end_to_end_id"),
          @payload.dig("pix_transfer", "transaction_id")
        ].map { |value| normalize_identifier(value) }.compact.uniq
      end

      def request_control_key_candidates
        [
          @payload["request_control_key"],
          @payload["external_reference"],
          @payload["idempotency_key"],
          @payload.dig("pix_transfer", "request_control_key")
        ].map { |value| normalize_identifier(value) }.compact.uniq
      end

      def account_id_candidates
        [
          @payload["account_key"],
          @payload["provider_account_id"],
          @payload.dig("account", "account_key"),
          @payload.dig("account_info", "account_key")
        ].map { |value| normalize_identifier(value) }.compact.uniq
      end

      def account_request_id_candidates
        [
          @payload["account_request_key"],
          @payload["provider_request_id"],
          @payload.dig("account", "account_request_key")
        ].map { |value| normalize_identifier(value) }.compact.uniq
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
        ActionIpLog.create!(
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
        )
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
