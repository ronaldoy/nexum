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
    assert_equal "supplier_user", user.reload.role
    assert_equal "supplier_user", user.roles.pick(:code)
  end

  test "users sessions and tenants enforce forced RLS" do
    rows = User.connection.select_rows(<<~SQL)
      SELECT relname, relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE relname IN ('users', 'sessions', 'tenants')
      ORDER BY relname
    SQL

    assert_equal 3, rows.size
    rows.each do |relname, rls_enabled, force_rls|
      assert_equal true, rls_enabled, "#{relname} must have RLS enabled"
      assert_equal true, force_rls, "#{relname} must have forced RLS"
    end
  end

  test "users sessions and tenants tenant policies exist" do
    rows = User.connection.select_rows(<<~SQL)
      SELECT tablename, policyname
      FROM pg_policies
      WHERE tablename IN ('users', 'sessions', 'tenants')
      ORDER BY tablename, policyname
    SQL

    assert_includes rows, [ "users", "users_tenant_policy" ]
    assert_includes rows, [ "sessions", "sessions_tenant_policy" ]
    assert_includes rows, [ "tenants", "tenants_self_policy" ]
  end

  test "active storage tables enforce forced RLS" do
    rows = User.connection.select_rows(<<~SQL)
      SELECT relname, relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE relname IN ('active_storage_blobs', 'active_storage_attachments', 'active_storage_variant_records')
      ORDER BY relname
    SQL

    assert_equal 3, rows.size
    rows.each do |relname, rls_enabled, force_rls|
      assert_equal true, rls_enabled, "#{relname} must have RLS enabled"
      assert_equal true, force_rls, "#{relname} must have forced RLS"
    end
  end

  test "active storage tenant policies exist" do
    rows = User.connection.select_rows(<<~SQL)
      SELECT tablename, policyname
      FROM pg_policies
      WHERE tablename IN ('active_storage_blobs', 'active_storage_attachments', 'active_storage_variant_records')
      ORDER BY tablename, policyname
    SQL

    assert_includes rows, [ "active_storage_blobs", "active_storage_blobs_tenant_policy" ]
    assert_includes rows, [ "active_storage_attachments", "active_storage_attachments_tenant_policy" ]
    assert_includes rows, [ "active_storage_variant_records", "active_storage_variant_records_tenant_policy" ]
  end

  test "validates MFA codes for privileged profiles" do
    user = User.create!(
      tenant: @tenant,
      role: "ops_admin",
      email_address: "ops-mfa@example.com",
      password: "Password@2026",
      password_confirmation: "Password@2026",
      mfa_enabled: true,
      mfa_secret: ROTP::Base32.random
    )

    code = ROTP::TOTP.new(user.mfa_secret).now
    assert user.mfa_required_for_role?
    assert user.valid_mfa_code?(code)
    refute user.valid_mfa_code?(code)
    assert user.reload.mfa_last_otp_at.present?
    refute user.valid_mfa_code?("000000")
  end
end
