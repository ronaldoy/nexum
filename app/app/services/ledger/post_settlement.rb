module Ledger
  class PostSettlement
    SETTLEMENT_SOURCE_TYPE = "ReceivablePaymentSettlement".freeze

    def initialize(tenant_id:, request_id:, actor_party_id: nil, actor_role: nil)
      @tenant_id = tenant_id
      @request_id = request_id
      @actor_party_id = actor_party_id
      @actor_role = actor_role
    end

    def call(settlement:, receivable:, allocation:, cnpj_amount:, fdic_amount:, beneficiary_amount:, paid_at:)
      entries = settlement_entries(
        settlement: settlement,
        receivable: receivable,
        allocation: allocation,
        cnpj_amount: cnpj_amount,
        fdic_amount: fdic_amount,
        beneficiary_amount: beneficiary_amount
      )
      return [] if entries.empty?

      post_transaction_service.call(
        txn_id: SecureRandom.uuid,
        receivable_id: receivable.id,
        payment_reference: settlement.payment_reference,
        posted_at: paid_at,
        source_type: SETTLEMENT_SOURCE_TYPE,
        source_id: settlement.id,
        entries: entries
      )
    end

    private

    def post_transaction_service
      @post_transaction_service ||= PostTransaction.new(
        tenant_id: @tenant_id,
        request_id: @request_id,
        actor_party_id: @actor_party_id,
        actor_role: @actor_role
      )
    end

    def settlement_entries(settlement:, receivable:, allocation:, cnpj_amount:, fdic_amount:, beneficiary_amount:)
      paid_amount = settlement.paid_amount.to_d
      debtor_party_id = receivable.debtor_party_id
      entries = base_settlement_entries(paid_amount: paid_amount, debtor_party_id: debtor_party_id)
      entries.concat(cnpj_entries(allocation: allocation, cnpj_amount: cnpj_amount))
      entries.concat(fdic_entries(fdic_amount: fdic_amount))
      entries.concat(beneficiary_entries(receivable: receivable, beneficiary_amount: beneficiary_amount))
      entries
    end

    def base_settlement_entries(paid_amount:, debtor_party_id:)
      [
        { account_code: "clearing:settlement", entry_side: "DEBIT", amount: paid_amount, party_id: debtor_party_id },
        { account_code: "receivables:hospital", entry_side: "CREDIT", amount: paid_amount, party_id: debtor_party_id }
      ]
    end

    def cnpj_entries(allocation:, cnpj_amount:)
      return [] unless positive_amount?(cnpj_amount)

      amount = cnpj_amount.to_d
      cnpj_party_id = resolve_cnpj_party_id(allocation)
      [
        { account_code: "obligations:cnpj", entry_side: "DEBIT", amount: amount, party_id: cnpj_party_id },
        { account_code: "clearing:settlement", entry_side: "CREDIT", amount: amount, party_id: cnpj_party_id }
      ]
    end

    def fdic_entries(fdic_amount:)
      return [] unless positive_amount?(fdic_amount)

      amount = fdic_amount.to_d
      fdic_party_id = resolve_fdic_party_id
      [
        { account_code: "obligations:fdic", entry_side: "DEBIT", amount: amount, party_id: fdic_party_id },
        { account_code: "clearing:settlement", entry_side: "CREDIT", amount: amount, party_id: fdic_party_id }
      ]
    end

    def beneficiary_entries(receivable:, beneficiary_amount:)
      return [] unless positive_amount?(beneficiary_amount)

      amount = beneficiary_amount.to_d
      beneficiary_party_id = receivable.beneficiary_party_id
      [
        { account_code: "obligations:beneficiary", entry_side: "DEBIT", amount: amount, party_id: beneficiary_party_id },
        { account_code: "clearing:settlement", entry_side: "CREDIT", amount: amount, party_id: beneficiary_party_id }
      ]
    end

    def positive_amount?(value)
      value.to_d > 0
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
