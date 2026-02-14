require "digest"
require "json"
require "bigdecimal"

module CanonicalJson
  module_function

  def encode(value)
    case value
    when Hash
      "{" + value.sort_by { |k, _| k.to_s }.map { |k, v| "#{k.to_s.to_json}:#{encode(v)}" }.join(",") + "}"
    when Array
      "[" + value.map { |entry| encode(entry) }.join(",") + "]"
    when BigDecimal
      value.to_s("F").to_json
    else
      value.to_json
    end
  end

  def digest(value)
    Digest::SHA256.hexdigest(encode(value))
  end
end
