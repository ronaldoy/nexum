module DocumentNumberMasker
  module_function

  def mask(value)
    raw = value.to_s.strip
    return nil if raw.blank?
    return raw if raw.include?("*")

    digits = raw.gsub(/\D+/, "")
    return nil if digits.blank?

    case digits.length
    when 11
      "***.***.***-#{digits[-2, 2]}"
    when 14
      "**.***.***/****-#{digits[-2, 2]}"
    else
      "#{('*' * [ digits.length - 4, 0 ].max)}#{digits[-4, 4]}"
    end
  end
end
