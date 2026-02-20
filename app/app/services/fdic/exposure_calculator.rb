module Fdic
  class ExposureCalculator
    OPEN_STATUSES = %w[APPROVED FUNDED SETTLED].freeze
    ZERO = BigDecimal("0")

    Result = Struct.new(
      :exposed,
      :contractual_obligation,
      :settled_amount,
      :contractual_outstanding,
      :accrued_discount,
      :accrued_outstanding,
      :term_business_days,
      :elapsed_business_days,
      keyword_init: true
    ) do
      def effective_contractual_exposure
        exposed ? contractual_outstanding : BigDecimal("0")
      end

      def effective_accrued_exposure
        exposed ? accrued_outstanding : BigDecimal("0")
      end
    end

    def initialize(valuation_time: Time.current)
      @valuation_time = valuation_time
    end

    def call(anticipation_request:, due_at:)
      requested_amount, discount_amount = requested_and_discount_amounts(anticipation_request)
      settled_amount = settled_amount_for(anticipation_request)
      term_business_days, elapsed_business_days = business_day_window(
        start_time: anticipation_request.requested_at || @valuation_time,
        due_at:
      )
      contractual_obligation, contractual_outstanding = contractual_exposure_values(
        requested_amount: requested_amount,
        discount_amount: discount_amount,
        settled_amount: settled_amount
      )
      accrued_discount, accrued_outstanding = accrued_exposure_values(
        requested_amount: requested_amount,
        discount_amount: discount_amount,
        settled_amount: settled_amount,
        term_business_days: term_business_days,
        elapsed_business_days: elapsed_business_days
      )

      exposure_result(
        anticipation_request: anticipation_request,
        contractual_obligation: contractual_obligation,
        settled_amount: settled_amount,
        contractual_outstanding: contractual_outstanding,
        accrued_discount: accrued_discount,
        accrued_outstanding: accrued_outstanding,
        term_business_days: term_business_days,
        elapsed_business_days: elapsed_business_days
      )
    end

    private

    def requested_and_discount_amounts(anticipation_request)
      [ anticipation_request.requested_amount.to_d, anticipation_request.discount_amount.to_d ]
    end

    def contractual_exposure_values(requested_amount:, discount_amount:, settled_amount:)
      contractual_obligation = FinancialRounding.money(requested_amount + discount_amount)
      contractual_outstanding = positive_money(contractual_obligation - settled_amount)
      [ contractual_obligation, contractual_outstanding ]
    end

    def accrued_exposure_values(requested_amount:, discount_amount:, settled_amount:, term_business_days:, elapsed_business_days:)
      accrued_discount = accrued_discount_value(
        discount_amount: discount_amount,
        term_business_days: term_business_days,
        elapsed_business_days: elapsed_business_days
      )
      accrued_obligation = FinancialRounding.money(requested_amount + accrued_discount)
      accrued_outstanding = positive_money(accrued_obligation - settled_amount)
      [ accrued_discount, accrued_outstanding ]
    end

    def accrued_discount_value(discount_amount:, term_business_days:, elapsed_business_days:)
      return FinancialRounding.money(discount_amount) unless term_business_days.positive?

      accrual_fraction = BigDecimal(elapsed_business_days.to_s) / BigDecimal(term_business_days.to_s)
      FinancialRounding.money(discount_amount * accrual_fraction)
    end

    def exposure_result(
      anticipation_request:,
      contractual_obligation:,
      settled_amount:,
      contractual_outstanding:,
      accrued_discount:,
      accrued_outstanding:,
      term_business_days:,
      elapsed_business_days:
    )
      Result.new(
        exposed: OPEN_STATUSES.include?(anticipation_request.status),
        contractual_obligation: contractual_obligation,
        settled_amount: settled_amount,
        contractual_outstanding: contractual_outstanding,
        accrued_discount: accrued_discount,
        accrued_outstanding: accrued_outstanding,
        term_business_days: term_business_days,
        elapsed_business_days: elapsed_business_days
      )
    end

    def settled_amount_for(anticipation_request)
      settled_total = if anticipation_request.association(:anticipation_settlement_entries).loaded?
        anticipation_request.anticipation_settlement_entries.sum { |entry| entry.settled_amount.to_d }
      else
        anticipation_request.anticipation_settlement_entries.sum(:settled_amount).to_d
      end

      FinancialRounding.money(settled_total)
    end

    def business_day_window(start_time:, due_at:)
      return [ 0, 0 ] if due_at.blank?

      tz = BusinessCalendar.time_zone
      start_date = start_time.in_time_zone(tz).to_date
      due_date = due_at.in_time_zone(tz).to_date

      total_days = BusinessCalendar.business_days_between(start_date: start_date, end_date: due_date)
      return [ 0, 0 ] if total_days <= 0

      valuation_date = [ @valuation_time.in_time_zone(tz).to_date, due_date ].min
      elapsed_days = BusinessCalendar.business_days_between(start_date: start_date, end_date: valuation_date)
      elapsed_days = [ [ elapsed_days, 0 ].max, total_days ].min

      [ total_days, elapsed_days ]
    end

    def positive_money(value)
      FinancialRounding.money([ value.to_d, ZERO ].max)
    end
  end
end
