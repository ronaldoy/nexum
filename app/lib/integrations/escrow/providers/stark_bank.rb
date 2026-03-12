require "date"
require "digest"
require "integrations/escrow/providers/base"
require "integrations/escrow/providers/stark_bank_configuration"
require "starkbank"

module Integrations
  module Escrow
    module Providers
      class StarkBank < Base
        PROVIDER_CODE = "STARKBANK".freeze
        PAYOUT_QUERY_LOOKBACK_DAYS = 7
        INTERNAL_TRANSFER_DESCRIPTION = "Nexum workspace funding".freeze

        def provider_code
          PROVIDER_CODE
        end

        def account_from_party_metadata(party:)
          raw = normalized_hash(
            party.metadata&.dig("integrations", "starkbank", "workspace") ||
            party.metadata&.dig("starkbank_workspace")
          )
          workspace_id = raw["id"].presence || raw["workspace_id"].presence
          return nil if workspace_id.blank?

          {
            provider_account_id: workspace_id,
            provider_request_id: raw["username"],
            status: raw["status"].presence || "ACTIVE",
            metadata: {
              "source" => "party_metadata",
              "workspace" => raw
            }
          }
        end

        def open_escrow_account!(tenant_id:, party:, idempotency_key:, metadata:)
          tenant_slug = tenant_slug_for(tenant_id)
          workspace = nil

          workspace = existing_workspace_for(tenant_slug:, party:)
          workspace ||= create_workspace!(tenant_slug:, party:, idempotency_key:)

          AccountProvisionResult.new(
            provider_account_id: workspace.fetch("id"),
            provider_request_id: workspace["username"],
            status: map_workspace_status(workspace["status"]),
            metadata: {
              "workspace" => workspace,
              "request_metadata" => normalized_hash(metadata)
            }
          )
        end

        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          raise ValidationError.new(code: "unsupported_currency", message: "Only BRL is supported for escrow payouts.") unless currency.to_s.upcase == "BRL"

          tenant_slug = tenant_slug_for(tenant_id)
          payout = load_payout_record(tenant_id:, idempotency_key:, metadata:)
          receiving_account = load_receiving_account!(tenant_id:, recipient_party:)
          source_workspace_id = StarkBankConfiguration.source_workspace_id_for(tenant_id:, tenant_slug:)
          source_user = StarkBankConfiguration.workspace_user(workspace_id: source_workspace_id, tenant_id:, tenant_slug:)
          destination_workspace_id = escrow_account.provider_account_id.to_s
          destination_user = StarkBankConfiguration.workspace_user(workspace_id: destination_workspace_id, tenant_id:, tenant_slug:)
          batch = current_batch_for(payout)
          batch_allocated_now = false
          unless batch
            batch = allocate_batch!(
              tenant_id:,
              tenant_slug:,
              source_workspace_id: source_workspace_id,
              amount: amount
            )
            batch_allocated_now = true
            batch = assign_batch_to_payout!(payout:, batch:) || batch
          end

          internal_transaction = nil
          internal_transaction = ensure_internal_transaction!(
            source_user:,
            receiver_workspace_id: destination_workspace_id,
            amount: amount,
            idempotency_key: idempotency_key,
            metadata: metadata
          )
          transfer = ensure_pix_transfer!(
            destination_user:,
            recipient_party: recipient_party,
            receiving_account: receiving_account,
            amount: amount,
            idempotency_key: idempotency_key,
            metadata: metadata
          )

          fee_amount = cents_to_decimal(internal_transaction["fee"]) + cents_to_decimal(transfer.fee)
          provider_status = transfer.status.to_s.downcase
          now = Time.current

          finalize_batch!(
            batch: batch,
            amount: amount,
            fee_amount: fee_amount
          )

          PayoutResult.new(
            provider_transfer_id: transfer.id,
            status: map_transfer_status(provider_status),
            provider_status: provider_status,
            provider_fee_amount: fee_amount,
            provider_fee_currency: "BRL",
            provider_source_account_id: source_workspace_id,
            provider_destination_account_id: destination_workspace_id,
            provider_end_to_end_id: Array(transfer.transaction_ids).presence&.last,
            confirmed_at: transfer_success?(provider_status) ? now : nil,
            batch_id: batch.id,
            metadata: {
              "internal_transaction" => internal_transaction,
              "transfer" => transfer_payload(transfer),
              "receiving_account" => {
                "bank_code" => receiving_account.bank_code,
                "account_type" => receiving_account.account_type,
                "masked_account_number" => receiving_account.masked_account_number
              }
            }
          )
        rescue ValidationError
          release_batch_reservation!(batch: batch, payout: payout, amount: amount) if batch_allocated_now && internal_transaction.blank?
          raise
        rescue RemoteError
          release_batch_reservation!(batch: batch, payout: payout, amount: amount) if batch_allocated_now && internal_transaction.blank?
          raise
        rescue ::StarkCore::Error::InputErrors => error
          release_batch_reservation!(batch: batch, payout: payout, amount: amount) if batch_allocated_now && internal_transaction.blank?
          raise_input_error!(error)
        rescue ::StarkCore::Error::StarkCoreError => error
          release_batch_reservation!(batch: batch, payout: payout, amount: amount) if batch_allocated_now && internal_transaction.blank?
          raise RemoteError.new(
            code: "starkbank_request_failed",
            message: error.message,
            http_status: 502,
            details: { error_class: error.class.name }
          )
        end

        def fetch_payout!(tenant_id:, payout:)
          tenant_slug = tenant_slug_for(tenant_id)
          workspace_id = payout.escrow_account.provider_account_id.to_s
          user = StarkBankConfiguration.workspace_user(workspace_id:, tenant_id:, tenant_slug:)
          transfer = ::StarkBank::Transfer.get(payout.provider_transfer_id, user:)
          provider_status = transfer.status.to_s.downcase
          fee_amount = cents_to_decimal(transfer.fee)

          PayoutResult.new(
            provider_transfer_id: transfer.id,
            status: map_transfer_status(provider_status),
            provider_status: provider_status,
            provider_fee_amount: fee_amount,
            provider_fee_currency: "BRL",
            provider_source_account_id: payout.provider_source_account_id,
            provider_destination_account_id: workspace_id,
            provider_end_to_end_id: Array(transfer.transaction_ids).presence&.last,
            confirmed_at: transfer_success?(provider_status) ? Time.current : nil,
            batch_id: payout.escrow_payout_batch_id,
            metadata: { "transfer" => transfer_payload(transfer) }
          )
        rescue ::StarkCore::Error::StarkCoreError => error
          raise RemoteError.new(
            code: "starkbank_status_sync_failed",
            message: error.message,
            http_status: 502,
            details: { error_class: error.class.name }
          )
        end

        private

        def tenant_slug_for(tenant_id)
          StarkBankConfiguration.tenant_slug_for(tenant_id:)
        end

        def existing_workspace_for(tenant_slug:, party:)
          username = workspace_username_for(tenant_slug:, party:)
          workspace = ::StarkBank::Workspace.query(
            limit: 1,
            username: username,
            user: organization_user(tenant_slug:)
          ).to_a.first
          workspace_payload(workspace)
        end

        def create_workspace!(tenant_slug:, party:, idempotency_key:)
          workspace = ::StarkBank::Workspace.create(
            username: workspace_username_for(tenant_slug:, party:),
            name: workspace_name_for(party),
            allowed_tax_ids: [ party.document_number ],
            user: organization_user(tenant_slug:)
          )

          payload = workspace_payload(workspace)
          payload["creation_idempotency_key"] = idempotency_key
          payload
        end

        def workspace_username_for(tenant_slug:, party:)
          slug = tenant_slug.to_s.parameterize.presence || "nexum"
          token = party.id.delete("-").first(16)
          "#{slug}-#{party.kind.to_s.downcase.first(4)}-#{token}".first(60)
        end

        def workspace_name_for(party)
          "Nexum #{party.legal_name}".truncate(80)
        end

        def map_workspace_status(raw_status)
          status = raw_status.to_s.downcase
          return "ACTIVE" if status.in?(%w[active])
          return "REJECTED" if status.in?(%w[blocked closed frozen])

          "PENDING"
        end

        def load_receiving_account!(tenant_id:, recipient_party:)
          ReceivingAccount
            .active
            .primary_account
            .find_by!(tenant_id:, party_id: recipient_party.id)
        rescue ActiveRecord::RecordNotFound
          raise ValidationError.new(
            code: "receiving_account_missing",
            message: "The recipient party must register an active PIX receiving account before Stark Bank payouts can be sent.",
            details: { party_id: recipient_party.id }
          )
        end

        def allocate_batch!(tenant_id:, tenant_slug:, source_workspace_id:, amount:)
          balance = ::StarkBank::Balance.get(
            user: StarkBankConfiguration.workspace_user(workspace_id: source_workspace_id, tenant_id:, tenant_slug:)
          )
          balance_amount = cents_to_decimal(balance.amount)
          risk_limit_amount = StarkBankConfiguration.risk_limit_amount_for(tenant_id:, tenant_slug:)

          Integrations::Escrow::StarkBank::AllocateBatch.new(
            tenant_id: tenant_id,
            provider: provider_code,
            source_provider_account_id: source_workspace_id,
            amount: amount,
            risk_limit_amount: risk_limit_amount,
            balance_amount: balance_amount
          ).call
        end

        def finalize_batch!(batch:, amount:, fee_amount:)
          batch.with_lock do
            now = Time.current
            batch.dispatched_amount = batch.dispatched_amount.to_d + amount.to_d
            batch.fee_amount = batch.fee_amount.to_d + fee_amount.to_d
            batch.last_polled_at = now
            if batch.reserved_amount.to_d >= batch.balance_snapshot_amount.to_d || batch.reserved_amount.to_d >= batch.risk_limit_amount.to_d
              batch.status = "CLOSED"
              batch.closed_at ||= now
            end
            batch.save!
          end
        end

        def release_batch_reservation!(batch:, payout:, amount:)
          return if batch.blank?

          batch.with_lock do
            batch.reserved_amount = [ batch.reserved_amount.to_d - amount.to_d, 0.to_d ].max
            batch.last_polled_at = Time.current
            if batch.status == "CLOSED" && batch.remaining_capacity.positive? && batch.available_snapshot_budget.positive?
              batch.status = "OPEN"
              batch.closed_at = nil
            end
            batch.save!
          end

          clear_batch_from_payout!(payout:) if payout.present?
        end

        def ensure_internal_transaction!(source_user:, receiver_workspace_id:, amount:, idempotency_key:, metadata:)
          external_id = "#{idempotency_key}:workspace"
          existing = ::StarkBank::Transaction.query(limit: 1, external_ids: [ external_id ], user: source_user).to_a.first
          return transaction_payload(existing) if existing

          response = ::StarkBank::Request.post(
            path: "transaction",
            payload: {
              "transactions" => [
                {
                  "amount" => decimal_to_cents(amount),
                  "description" => internal_transfer_description(metadata),
                  "externalId" => external_id,
                  "receiverId" => receiver_workspace_id,
                  "tags" => transaction_tags(idempotency_key)
                }
              ]
            },
            user: source_user
          )
          return response.json.fetch("transactions").first if response.status == 200

          recovered = ::StarkBank::Transaction.query(limit: 1, external_ids: [ external_id ], user: source_user).to_a.first
          return transaction_payload(recovered) if recovered

          raise_remote_request_error!(
            code: "starkbank_workspace_funding_failed",
            message: "Unable to move funds to the recipient Stark Bank workspace.",
            response: response
          )
        end

        def ensure_pix_transfer!(destination_user:, recipient_party:, receiving_account:, amount:, idempotency_key:, metadata:)
          existing = existing_transfer_for(destination_user:, idempotency_key:)
          return existing if existing

          transfer = ::StarkBank::Transfer.new(
            amount: decimal_to_cents(amount),
            bank_code: receiving_account.bank_code,
            branch_code: receiving_account.branch_code,
            account_number: receiving_account.account_number,
            account_type: receiving_account.account_type,
            external_id: "#{idempotency_key}:pix",
            tax_id: receiving_account.holder_document_number,
            name: receiving_account.holder_name,
            description: payout_description(metadata),
            display_description: payout_description(metadata),
            tags: transfer_tags(idempotency_key, recipient_party)
          )

          ::StarkBank::Transfer.create([ transfer ], user: destination_user).first
        rescue ::StarkCore::Error::InputErrors
          recovered = existing_transfer_for(destination_user:, idempotency_key:)
          return recovered if recovered

          raise
        end

        def existing_transfer_for(destination_user:, idempotency_key:)
          tag = transfer_identity_tag(idempotency_key)
          after_date = Date.current - PAYOUT_QUERY_LOOKBACK_DAYS
          ::StarkBank::Transfer
            .query(limit: 20, after: after_date, tags: [ tag ], user: destination_user)
            .to_a
            .find { |transfer| transfer.external_id.to_s == "#{idempotency_key}:pix" || Array(transfer.tags).include?(tag) }
        end

        def map_transfer_status(provider_status)
          return "SENT" if transfer_success?(provider_status)
          return "FAILED" if transfer_failed?(provider_status)

          "PROCESSING"
        end

        def final_transfer_status?(provider_status)
          transfer_success?(provider_status) || transfer_failed?(provider_status)
        end

        def transfer_success?(provider_status)
          provider_status.in?(%w[success successful])
        end

        def transfer_failed?(provider_status)
          provider_status.in?(%w[failed canceled cancelled rejected])
        end

        def organization_user(tenant_slug:)
          StarkBankConfiguration.organization_user(tenant_slug:, workspace_id: nil)
        end

        def load_payout_record(tenant_id:, idempotency_key:, metadata:)
          payout_idempotency_key = metadata["payout_idempotency_key"].to_s.presence ||
            metadata["provider_request_control_key"].to_s.presence ||
            idempotency_key.to_s.presence
          return nil if payout_idempotency_key.blank?

          EscrowPayout.find_by(tenant_id:, idempotency_key: payout_idempotency_key)
        end

        def current_batch_for(payout)
          return nil if payout&.escrow_payout_batch_id.blank?

          EscrowPayoutBatch.find_by(id: payout.escrow_payout_batch_id)
        end

        def assign_batch_to_payout!(payout:, batch:)
          return batch if payout.blank?

          payout.with_lock do
            if payout.escrow_payout_batch_id.present? && payout.escrow_payout_batch_id != batch.id
              return EscrowPayoutBatch.find_by(id: payout.escrow_payout_batch_id) || batch
            end

            payout.update!(escrow_payout_batch_id: batch.id) if payout.escrow_payout_batch_id.blank?
            batch
          end
        end

        def clear_batch_from_payout!(payout:)
          payout.with_lock do
            payout.update!(escrow_payout_batch_id: nil)
          end
        end

        def payout_description(metadata)
          settlement_id = metadata["settlement_id"].to_s.presence
          anticipation_request_id = metadata["anticipation_request_id"].to_s.presence
          return "Repasse liquidação #{settlement_id.first(8)}" if settlement_id.present?
          return "Repasse antecipação #{anticipation_request_id.first(8)}" if anticipation_request_id.present?

          "Repasse operacional Nexum"
        end

        def internal_transfer_description(metadata)
          reference = metadata["payment_reference"].to_s.presence || metadata["settlement_id"].to_s.presence || INTERNAL_TRANSFER_DESCRIPTION
          "#{INTERNAL_TRANSFER_DESCRIPTION} #{reference}".truncate(64)
        end

        def transaction_tags(idempotency_key)
          [ "nexum", "workspace-funding", transfer_identity_tag(idempotency_key) ]
        end

        def transfer_tags(idempotency_key, recipient_party)
          [ "nexum", "escrow-payout", transfer_identity_tag(idempotency_key), recipient_party.id.to_s.first(8) ]
        end

        def transfer_identity_tag(idempotency_key)
          "idem-#{Digest::SHA256.hexdigest(idempotency_key.to_s).first(20)}"
        end

        def decimal_to_cents(value)
          (value.to_d * 100).round(0, BigDecimal::ROUND_HALF_UP).to_i
        end

        def cents_to_decimal(value)
          (BigDecimal(value.to_i.to_s) / 100).round(2)
        end

        def transaction_payload(transaction)
          return {} if transaction.blank?

          {
            "id" => transaction.id,
            "external_id" => transaction.external_id,
            "receiver_id" => transaction.receiver_id,
            "sender_id" => transaction.sender_id,
            "fee" => transaction.fee,
            "created" => transaction.created&.iso8601
          }.compact
        end

        def transfer_payload(transfer)
          {
            "id" => transfer.id,
            "status" => transfer.status,
            "fee" => transfer.fee,
            "external_id" => transfer.external_id,
            "transaction_ids" => transfer.transaction_ids,
            "created" => transfer.created&.iso8601,
            "updated" => transfer.updated&.iso8601
          }.compact
        end

        def workspace_payload(workspace)
          return nil if workspace.blank?
          return workspace if workspace.is_a?(Hash)

          {
            "id" => workspace.id,
            "username" => workspace.username,
            "name" => workspace.name,
            "status" => workspace.status,
            "organization_id" => workspace.organization_id,
            "picture_url" => workspace.picture_url,
            "created" => workspace.created&.iso8601
          }.compact
        end

        def normalized_hash(value)
          case value
          when ActionController::Parameters
            normalized_hash(value.to_unsafe_h)
          when Hash
            value.each_with_object({}) do |(key, entry), output|
              output[key.to_s] = normalized_hash(entry)
            end
          when Array
            value.map { |entry| normalized_hash(entry) }
          else
            value
          end
        end

        def raise_remote_request_error!(code:, message:, response:)
          details = {}
          details["status"] = response.status if response.respond_to?(:status)
          details["body"] = response.json if response.respond_to?(:json)

          raise RemoteError.new(
            code: code,
            message: message,
            http_status: response.respond_to?(:status) ? response.status : 502,
            details: details
          )
        end

        def raise_input_error!(error)
          first_error = Array(error.errors).first
          raise ValidationError.new(
            code: first_error&.code || "starkbank_validation_error",
            message: first_error&.message || error.message
          )
        end
      end
    end
  end
end
