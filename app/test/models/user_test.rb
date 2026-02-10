require "test_helper"

class UserTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
  end

  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "encrypts email_address at rest and preserves authentication" do
    user = User.create!(
      tenant: @tenant,
      role: "supplier_user",
      email_address: "sensitive@example.com",
      password: "Password@2026",
      password_confirmation: "Password@2026"
    )

    raw_email = User.connection.select_value(
      "SELECT email_address FROM users WHERE id = #{User.connection.quote(user.id)}"
    )

    refute_equal "sensitive@example.com", raw_email
    assert_equal user.id, User.authenticate_by(email_address: "sensitive@example.com", password: "Password@2026")&.id
  end
end
