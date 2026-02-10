class EnforceBrlCurrencyOnReceivables < ActiveRecord::Migration[8.2]
  def change
    add_check_constraint :receivables, "currency = 'BRL'", name: "receivables_currency_brl_check"
  end
end
