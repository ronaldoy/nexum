require "test_helper"

module Security
  class DatabaseRoleGuardTest < ActiveSupport::TestCase
    FakeConnection = Struct.new(:row, keyword_init: true) do
      def select_one(*)
        row
      end

      def select_value(*)
        row&.fetch("role_name", "app")
      end
    end

    test "secure? returns true for non-superuser non-bypass role" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => false, "rolbypassrls" => false }
      )

      assert_equal true, DatabaseRoleGuard.secure?(connection:)
    end

    test "secure? returns false for bypass rls role" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => false, "rolbypassrls" => true }
      )

      assert_equal false, DatabaseRoleGuard.secure?(connection:)
    end

    test "ensure_secure! raises when enforcement is enabled and role is insecure" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => true, "rolbypassrls" => false }
      )

      with_environment("DB_ROLE_SECURITY_ENFORCED" => "true", "DB_ROLE_SECURITY_ALLOW_INSECURE" => "false") do
        error = assert_raises(RuntimeError) do
          DatabaseRoleGuard.ensure_secure!(connection:)
        end

        assert_match(/Database role security violation/, error.message)
      end
    end

    test "readiness status returns ok when readiness check is disabled" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => true, "rolbypassrls" => true }
      )

      with_environment("DB_ROLE_SECURITY_READY_CHECK_ENABLED" => "false") do
        assert_equal "ok", DatabaseRoleGuard.readiness_status(connection:)
      end
    end

    private

    def with_environment(overrides)
      previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
      overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end
end
