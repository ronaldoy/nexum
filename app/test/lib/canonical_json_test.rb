require "test_helper"
require "bigdecimal"

class CanonicalJsonTest < ActiveSupport::TestCase
  test "sorts hash keys alphabetically" do
    result = CanonicalJson.encode({ "z" => 1, "a" => 2, "m" => 3 })
    assert_equal '{"a":2,"m":3,"z":1}', result
  end

  test "sorts symbol keys by string representation" do
    result = CanonicalJson.encode({ z: 1, a: 2 })
    assert_equal '{"a":2,"z":1}', result
  end

  test "sorts nested hash keys" do
    result = CanonicalJson.encode({ b: { z: 1, a: 2 }, a: 3 })
    assert_equal '{"a":3,"b":{"a":2,"z":1}}', result
  end

  test "encodes arrays preserving order" do
    result = CanonicalJson.encode([ 3, 1, 2 ])
    assert_equal "[3,1,2]", result
  end

  test "encodes arrays of hashes" do
    result = CanonicalJson.encode([ { b: 1, a: 2 }, { d: 3, c: 4 } ])
    assert_equal '[{"a":2,"b":1},{"c":4,"d":3}]', result
  end

  test "encodes BigDecimal with full precision" do
    result = CanonicalJson.encode(BigDecimal("123.45"))
    assert_equal '"123.45"', result
  end

  test "encodes BigDecimal with trailing zeros" do
    result = CanonicalJson.encode(BigDecimal("100.00"))
    assert_equal '"100.0"', result
  end

  test "encodes strings" do
    result = CanonicalJson.encode("hello")
    assert_equal '"hello"', result
  end

  test "encodes nil" do
    result = CanonicalJson.encode(nil)
    assert_equal "null", result
  end

  test "encodes booleans" do
    assert_equal "true", CanonicalJson.encode(true)
    assert_equal "false", CanonicalJson.encode(false)
  end

  test "encodes integers" do
    assert_equal "42", CanonicalJson.encode(42)
  end

  test "digest returns SHA256 hex of canonical encoding" do
    value = { b: 1, a: 2 }
    expected = Digest::SHA256.hexdigest(CanonicalJson.encode(value))
    assert_equal expected, CanonicalJson.digest(value)
  end

  test "identical payloads with different key order produce same encoding" do
    a = CanonicalJson.encode({ name: "test", amount: "100.00", status: "ACTIVE" })
    b = CanonicalJson.encode({ status: "ACTIVE", name: "test", amount: "100.00" })
    assert_equal a, b
  end

  test "identical payloads with different key order produce same digest" do
    a = CanonicalJson.digest({ name: "test", amount: "100.00" })
    b = CanonicalJson.digest({ amount: "100.00", name: "test" })
    assert_equal a, b
  end
end
