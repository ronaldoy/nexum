module Integrations
  module Escrow
    class EnsurePaymentInstructions
      Result = Struct.new(
        :escrow_account,
        :operational_party,
        :receivable_allocation,
        :provider_code,
        :payment_instructions,
        keyword_init: true
      )

      def call(tenant_id:, receivable:, receivable_allocation: nil, idempotency_key: nil, provider_code: nil)
        allocation = resolve_receivable_allocation!(receivable:, receivable_allocation:)
        operational_party = allocation.allocated_party
        provider_code = resolve_provider_code(tenant_id:, operational_party:, provider_code:)
        provider = ProviderRegistry.fetch(provider_code:, tenant_id:)

        escrow_account = EnsureEscrowAccount.new.call(
          tenant_id: tenant_id,
          party: operational_party,
          provider: provider,
          idempotency_key: idempotency_key.presence || default_account_idempotency_key(operational_party),
          metadata: {
            "receivable_id" => receivable.id,
            "receivable_allocation_id" => allocation.id,
            "operational_party_id" => operational_party.id,
            "purpose" => "inbound_payment_instructions"
          }
        )

        payment_instructions = load_payment_instructions!(
          tenant_id: tenant_id,
          provider: provider,
          escrow_account: escrow_account
        )

        Result.new(
          escrow_account: escrow_account,
          operational_party: operational_party,
          receivable_allocation: allocation,
          provider_code: provider_code,
          payment_instructions: public_payment_instructions(
            operational_party: operational_party,
            payment_instructions: payment_instructions
          )
        )
      end

      private

      def resolve_receivable_allocation!(receivable:, receivable_allocation:)
        allocation = receivable_allocation || receivable.receivable_allocations.order(sequence: :asc).first
        if allocation.blank?
          raise ValidationError.new(
            code: "receivable_allocation_missing",
            message: "Receivable must have an allocation to resolve payment instructions."
          )
        end

        return allocation if allocation.receivable_id == receivable.id

        raise ValidationError.new(
          code: "receivable_allocation_invalid",
          message: "Receivable allocation does not belong to the requested receivable."
        )
      end

      def resolve_provider_code(tenant_id:, operational_party:, provider_code:)
        normalized = provider_code.to_s.strip.upcase
        return ProviderConfig.normalize_provider(normalized, tenant_id: tenant_id) if normalized.present?

        existing_provider = EscrowAccount.active.where(
          tenant_id: tenant_id,
          party_id: operational_party.id
        ).order(updated_at: :desc).pick(:provider)
        existing_provider ||= EscrowAccount.where(
          tenant_id: tenant_id,
          party_id: operational_party.id
        ).order(updated_at: :desc).pick(:provider)
        return ProviderConfig.normalize_provider(existing_provider, tenant_id: tenant_id) if existing_provider.present?

        ProviderConfig.default_provider(tenant_id: tenant_id)
      end

      def default_account_idempotency_key(operational_party)
        "#{operational_party.id}:escrow_account"
      end

      def load_payment_instructions!(tenant_id:, provider:, escrow_account:)
        cached_payment_instructions = normalized_hash(escrow_account.metadata&.dig("payment_instructions"))
        return cached_payment_instructions if valid_payment_instructions?(cached_payment_instructions)

        unless provider.respond_to?(:fetch_payment_instructions!)
          raise ValidationError.new(
            code: "payment_instructions_unavailable",
            message: "PIX payment instructions are unavailable for the configured escrow provider.",
            details: { provider: provider.provider_code }
          )
        end

        payment_instructions = normalized_hash(
          provider.fetch_payment_instructions!(
            tenant_id: tenant_id,
            escrow_account: escrow_account
          )
        )

        unless valid_payment_instructions?(payment_instructions)
          raise ValidationError.new(
            code: "payment_instructions_invalid",
            message: "Escrow provider returned invalid PIX payment instructions.",
            details: { provider: provider.provider_code }
          )
        end

        escrow_account.with_lock do
          escrow_account.metadata = merge_metadata(
            escrow_account.metadata,
            "payment_instructions" => payment_instructions
          )
          escrow_account.last_synced_at = Time.current
          escrow_account.save!
        end

        payment_instructions
      end

      def public_payment_instructions(operational_party:, payment_instructions:)
        {
          "payment_rail" => payment_instructions["payment_rail"],
          "pix_key" => payment_instructions["pix_key"],
          "pix_key_type" => payment_instructions["pix_key_type"],
          "pix_key_status" => payment_instructions["pix_key_status"],
          "bank_name" => payment_instructions["bank_name"],
          "bank_code" => payment_instructions["bank_code"],
          "account_type" => payment_instructions["account_type"],
          "beneficiary_name" => payment_instructions["beneficiary_name"].presence || operational_party.legal_name,
          "beneficiary_document_number" => operational_party.document_number,
          "last_synced_at" => payment_instructions["last_synced_at"]
        }.compact
      end

      def valid_payment_instructions?(payment_instructions)
        return false unless payment_instructions.is_a?(Hash)

        payment_instructions["payment_rail"].to_s.upcase == "PIX" &&
          payment_instructions["pix_key"].to_s.present?
      end

      def merge_metadata(existing, incoming)
        normalized_hash(existing).merge(normalized_hash(incoming))
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
    end
  end
end
