module Ledger
  class PostTransaction
    class ValidationError < StandardError
      attr_reader :code

      def initialize(code:, message:)
        super(message)
        @code = code
      end
    end

    def initialize(tenant_id:, request_id:)
      @tenant_id = tenant_id
      @request_id = request_id
    end

    def call(txn_id:, posted_at:, source_type:, source_id:, entries:, receivable_id: nil)
      validate_entries!(entries)

      existing = LedgerEntry.where(tenant_id: @tenant_id, txn_id: txn_id).order(:created_at).to_a
      return existing if existing.any?

      records = entries.map do |entry|
        LedgerEntry.create!(
          tenant_id: @tenant_id,
          txn_id: txn_id,
          receivable_id: receivable_id,
          account_code: entry[:account_code],
          entry_side: entry[:entry_side],
          amount: round_money(entry[:amount]),
          currency: "BRL",
          party_id: entry[:party_id],
          source_type: source_type,
          source_id: source_id,
          metadata: entry[:metadata] || {},
          posted_at: posted_at
        )
      end

      records
    end

    private

    def validate_entries!(entries)
      raise_validation_error!("empty_entries", "entries must not be empty.") if entries.blank?

      entries.each do |entry|
        unless ChartOfAccounts.valid_code?(entry[:account_code])
          raise_validation_error!("unknown_account_code", "unknown account code: #{entry[:account_code]}")
        end

        unless %w[DEBIT CREDIT].include?(entry[:entry_side])
          raise_validation_error!("invalid_entry_side", "entry_side must be DEBIT or CREDIT.")
        end
      end

      debit_sum = BigDecimal("0")
      credit_sum = BigDecimal("0")

      entries.each do |entry|
        rounded = round_money(entry[:amount])
        if entry[:entry_side] == "DEBIT"
          debit_sum += rounded
        else
          credit_sum += rounded
        end
      end

      return if debit_sum == credit_sum

      raise_validation_error!(
        "unbalanced_transaction",
        "transaction is unbalanced: debits=#{debit_sum.to_s('F')} credits=#{credit_sum.to_s('F')}"
      )
    end

    def round_money(value)
      FinancialRounding.money(value)
    end

    def raise_validation_error!(code, message)
      raise ValidationError.new(code:, message:)
    end
  end
end
