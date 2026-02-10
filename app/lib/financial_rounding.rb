module FinancialRounding
  module_function

  ROUND_MODE = BigDecimal::ROUND_UP
  MONEY_SCALE = 2
  RATE_SCALE = 8

  def money(value)
    decimal(value).round(MONEY_SCALE, ROUND_MODE)
  end

  def rate(value)
    decimal(value).round(RATE_SCALE, ROUND_MODE)
  end

  def decimal(value)
    value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
  end
end
