# frozen_string_literal: true

require "bigdecimal"

module MetadataSanitizer
  SENSITIVE_KEY_PATTERN = /
    cpf|cnpj|document|email|mail|phone|telefone|whatsapp|name|nome|rg|cnh|
    passport|address|endereco|birth|dob|token|secret|password|otp|crm|ssn|
    cvv|cvc
  /ix
  EMAIL_PATTERN = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
  SENSITIVE_DIGIT_LENGTHS = [ 11, 14 ].freeze
  DEFAULT_MAX_VALUE_LENGTH = 120

  module_function

  def sanitize(raw_metadata, allowed_keys:, max_value_length: DEFAULT_MAX_VALUE_LENGTH)
    metadata = normalize(raw_metadata)
    return {} unless metadata.is_a?(Hash)

    normalized_allowed_keys = normalize_allowed_keys(allowed_keys)
    metadata.each_with_object({}) do |(raw_key, raw_value), output|
      key = raw_key.to_s
      next unless normalized_allowed_keys.include?(key)
      next if sensitive_key?(key)

      sanitized_value = sanitize_value(raw_value, max_value_length:)
      next if sanitized_value.nil?

      output[key] = sanitized_value
    end
  end

  def normalize(raw_value)
    case raw_value
    when ActionController::Parameters
      normalize(raw_value.to_unsafe_h)
    when Hash
      raw_value.each_with_object({}) do |(key, value), output|
        output[key.to_s] = normalize(value)
      end
    when Array
      raw_value.map { |entry| normalize(entry) }
    else
      raw_value
    end
  end

  def normalize_allowed_keys(raw_allowed_keys)
    Array(raw_allowed_keys).flat_map { |value| value.to_s.split(",") }.map { |value| value.strip }.reject(&:blank?).uniq
  end
  private_class_method :normalize_allowed_keys

  def sensitive_key?(value)
    SENSITIVE_KEY_PATTERN.match?(value.to_s)
  end
  private_class_method :sensitive_key?

  def sensitive_value?(value)
    return false if value.blank?
    return true if EMAIL_PATTERN.match?(value)

    digits = value.gsub(/\D/, "")
    SENSITIVE_DIGIT_LENGTHS.include?(digits.length)
  end
  private_class_method :sensitive_value?

  def sanitize_value(raw_value, max_value_length:)
    case raw_value
    when String
      value = raw_value.strip
      return nil if value.blank?
      return nil if sensitive_value?(value)

      value[0, max_value_length]
    when Symbol
      sanitize_value(raw_value.to_s, max_value_length:)
    when Integer
      value = raw_value.to_s
      return nil if sensitive_value?(value)

      raw_value
    when Float
      nil
    when BigDecimal
      raw_value.to_s("F")
    when TrueClass, FalseClass
      raw_value
    else
      nil
    end
  end
  private_class_method :sanitize_value
end
