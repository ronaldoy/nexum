class LedgerEntry < ApplicationRecord
  CURRENCY = "BRL"
  ENTRY_SIDES = %w[DEBIT CREDIT].freeze

  belongs_to :tenant
  belongs_to :receivable, optional: true
  belongs_to :party, optional: true

  validates :txn_id, presence: true
  validates :entry_position, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :txn_entry_count, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :account_code, presence: true
  validates :entry_side, presence: true, inclusion: { in: ENTRY_SIDES }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true, inclusion: { in: [ CURRENCY ] }
  validates :source_type, presence: true
  validates :source_id, presence: true
  validates :posted_at, presence: true

  validate :account_code_must_be_known

  scope :debits, -> { where(entry_side: "DEBIT") }
  scope :credits, -> { where(entry_side: "CREDIT") }
  scope :for_account, ->(code) { where(account_code: code) }
  scope :for_transaction, ->(txn_id) { where(txn_id: txn_id) }

  def self.balance_for(account_code, tenant_id:)
    scope = where(tenant_id: tenant_id, account_code: account_code)
    debit_sum = scope.debits.sum(:amount)
    credit_sum = scope.credits.sum(:amount)

    if ChartOfAccounts.debit_normal?(account_code)
      debit_sum - credit_sum
    else
      credit_sum - debit_sum
    end
  end

  private

  def account_code_must_be_known
    return if account_code.blank?
    return if ChartOfAccounts.valid_code?(account_code)

    errors.add(:account_code, "is not a recognized account code")
  end
end
