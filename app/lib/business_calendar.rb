module BusinessCalendar
  module_function

  def time_zone
    ActiveSupport::TimeZone[Rails.configuration.x.business_timezone] || ActiveSupport::TimeZone["America/Sao_Paulo"]
  end

  def cutoff_at(date = time_zone.today)
    time_zone.parse("#{date} 23:59:59")
  end

  def next_business_day(from:)
    date = from.in_time_zone(time_zone).to_date

    loop do
      date += 1
      return date unless non_business_day?(date)
    end
  end

  # Counts business days in (start_date, end_date], excluding start_date and including end_date.
  def business_days_between(start_date:, end_date:)
    from = start_date.to_date
    to = end_date.to_date
    return 0 if to <= from

    count = 0
    date = from

    while date < to
      date += 1
      count += 1 unless non_business_day?(date)
    end

    count
  end

  def non_business_day?(date)
    date.saturday? || date.sunday? || holidays.include?(date)
  end

  def holidays
    entries = Array(Rails.app.creds.option(:business_calendar, :holidays, default: []))
    entries.map { |entry| Date.parse(entry.to_s) }.uniq
  rescue ArgumentError
    []
  end
end
