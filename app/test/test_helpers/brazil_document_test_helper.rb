require "digest"

module BrazilDocumentTestHelper
  def valid_cpf_from_seed(seed)
    base = numeric_seed(seed, size: 9)
    base = [ 1, 2, 3, 4, 5, 6, 7, 8, 9 ] if base.uniq.one?

    first_check = cpf_check_digit(base, 10)
    second_check = cpf_check_digit(base + [ first_check ], 11)

    (base + [ first_check, second_check ]).join
  end

  def valid_cnpj_from_seed(seed)
    base = numeric_seed(seed, size: 12)
    base = [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2 ] if base.uniq.one?

    first_check = cnpj_check_digit(base, [ 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 ])
    second_check = cnpj_check_digit(base + [ first_check ], [ 6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 ])

    (base + [ first_check, second_check ]).join
  end

  def format_cpf(cpf_digits)
    digits = cpf_digits.to_s.gsub(/\D+/, "")
    "#{digits[0, 3]}.#{digits[3, 3]}.#{digits[6, 3]}-#{digits[9, 2]}"
  end

  def format_cnpj(cnpj_digits)
    digits = cnpj_digits.to_s.gsub(/\D+/, "")
    "#{digits[0, 2]}.#{digits[2, 3]}.#{digits[5, 3]}/#{digits[8, 4]}-#{digits[12, 2]}"
  end

  private

  def numeric_seed(seed, size:)
    source = Digest::SHA256.hexdigest(seed.to_s).chars.map { |char| char.to_i(16) % 10 }
    values = []
    cursor = 0

    while values.length < size
      values << source[cursor % source.length]
      cursor += 1
    end

    values
  end

  def cpf_check_digit(values, weight_start)
    sum = values.each_with_index.sum { |value, index| value * (weight_start - index) }
    remainder = sum % 11
    remainder < 2 ? 0 : 11 - remainder
  end

  def cnpj_check_digit(values, weights)
    sum = values.each_with_index.sum { |value, index| value * weights[index] }
    remainder = sum % 11
    remainder < 2 ? 0 : 11 - remainder
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include BrazilDocumentTestHelper
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include BrazilDocumentTestHelper
end
