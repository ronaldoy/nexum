module Ledger
  class PostSettlement
    def initialize(tenant_id:, request_id:)
      @tenant_id = tenant_id
      @request_id = request_id
    end

    def call(settlement:, receivable:, allocation:, cnpj_amount:, fdic_amount:, beneficiary_amount:, paid_at:)
      txn_id = SecureRandom.uuid
      entries = build_entries(
        settlement: settlement,
        receivable: receivable,
        allocation: allocation,
        cnpj_amount: cnpj_amount,
        fdic_amount: fdic_amount,
        beneficiary_amount: beneficiary_amount
      )

      return [] if entries.empty?

      poster = PostTransaction.new(tenant_id: @tenant_id, request_id: @request_id)
      poster.call(
        txn_id: txn_id,
        receivable_id: receivable.id,
        posted_at: paid_at,
        source_type: "ReceivablePaymentSettlement",
        source_id: settlement.id,
        entries: entries
      )
    end

    private

    def build_entries(settlement:, receivable:, allocation:, cnpj_amount:, fdic_amount:, beneficiary_amount:)
      paid_amount = settlement.paid_amount.to_d
      debtor_party_id = receivable.debtor_party_id
      entries = []

      # Leg 1: Hospital payment enters clearing, receivable credited
      entries << { account_code: "clearing:settlement", entry_side: "DEBIT", amount: paid_amount, party_id: debtor_party_id }
      entries << { account_code: "receivables:hospital", entry_side: "CREDIT", amount: paid_amount, party_id: debtor_party_id }

      # Leg 2: CNPJ tax reserve (if applicable)
      if cnpj_amount.to_d > 0
        cnpj_party_id = resolve_cnpj_party_id(allocation)
        entries << { account_code: "obligations:cnpj", entry_side: "DEBIT", amount: cnpj_amount.to_d, party_id: cnpj_party_id }
        entries << { account_code: "clearing:settlement", entry_side: "CREDIT", amount: cnpj_amount.to_d, party_id: cnpj_party_id }
      end

      # Leg 3: FIDC repayment (if applicable)
      if fdic_amount.to_d > 0
        fdic_party_id = resolve_fdic_party_id
        entries << { account_code: "obligations:fdic", entry_side: "DEBIT", amount: fdic_amount.to_d, party_id: fdic_party_id }
        entries << { account_code: "clearing:settlement", entry_side: "CREDIT", amount: fdic_amount.to_d, party_id: fdic_party_id }
      end

      # Leg 4: Beneficiary remainder
      if beneficiary_amount.to_d > 0
        beneficiary_party_id = receivable.beneficiary_party_id
        entries << { account_code: "obligations:beneficiary", entry_side: "DEBIT", amount: beneficiary_amount.to_d, party_id: beneficiary_party_id }
        entries << { account_code: "clearing:settlement", entry_side: "CREDIT", amount: beneficiary_amount.to_d, party_id: beneficiary_party_id }
      end

      entries
    end

    def resolve_cnpj_party_id(allocation)
      return nil unless allocation

      allocation.allocated_party_id
    end

    def resolve_fdic_party_id
      fdic = Party.find_by(tenant_id: @tenant_id, kind: "FIDC")
      fdic&.id
    end
  end
end
