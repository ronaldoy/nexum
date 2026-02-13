module ChartOfAccounts
  module_function

  ACCOUNT_TYPES = %w[ASSET LIABILITY CLEARING REVENUE].freeze

  ACCOUNTS = {
    "receivables:hospital" => { type: "ASSET", description: "Money owed by hospitals" },
    "obligations:cnpj" => { type: "LIABILITY", description: "CNPJ tax reserve owed" },
    "obligations:fdic" => { type: "LIABILITY", description: "Owed to FIDC (anticipation repayment)" },
    "obligations:beneficiary" => { type: "LIABILITY", description: "Owed to physician/supplier" },
    "clearing:settlement" => { type: "CLEARING", description: "Transitory settlement clearing" },
    "revenue:discount" => { type: "REVENUE", description: "Anticipation discount earned by FIDC" }
  }.freeze

  CODES = ACCOUNTS.keys.freeze

  def valid_code?(code)
    ACCOUNTS.key?(code)
  end

  def account_type(code)
    ACCOUNTS.dig(code, :type)
  end

  def description(code)
    ACCOUNTS.dig(code, :description)
  end

  def debit_normal?(code)
    type = account_type(code)
    type == "ASSET" || type == "CLEARING"
  end
end
