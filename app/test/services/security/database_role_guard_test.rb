require "test_helper"

module Security
  class DatabaseRoleGuardTest < ActiveSupport::TestCase
    FakeConnection = Struct.new(:row, :public_table_ownership_count, keyword_init: true) do
      def select_one(sql)
        return row unless sql.include?("FROM pg_roles")

        row
      end

      def select_value(sql)
        return public_table_ownership_count.to_s if sql.include?("FROM pg_class c")

        row&.fetch("role_name", "app")
      end
    end

    test "secure? returns true for non-superuser non-bypass role" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => false, "rolbypassrls" => false },
        public_table_ownership_count: 0
      )

      assert_equal true, DatabaseRoleGuard.secure?(connection:)
    end

    test "secure? returns false for bypass rls role" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => false, "rolbypassrls" => true },
        public_table_ownership_count: 0
      )

      assert_equal false, DatabaseRoleGuard.secure?(connection:)
    end

    test "ensure_secure! raises when enforcement is enabled and role is insecure" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => true, "rolbypassrls" => false },
        public_table_ownership_count: 0
      )

      with_environment("DB_ROLE_SECURITY_ENFORCED" => "true", "DB_ROLE_SECURITY_ALLOW_INSECURE" => "false") do
        error = assert_raises(RuntimeError) do
          DatabaseRoleGuard.ensure_secure!(connection:)
        end

        assert_match(/Database role security violation/, error.message)
      end
    end

    test "audit! raises for insecure runtime role even when boot enforcement is disabled" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => false, "rolbypassrls" => false },
        public_table_ownership_count: 1
      )

      with_environment("DB_ROLE_SECURITY_ENFORCED" => "false", "DB_ROLE_SECURITY_ALLOW_INSECURE" => "true") do
        error = assert_raises(RuntimeError) do
          DatabaseRoleGuard.audit!(connection:)
        end

        assert_match(/Database role security violation/, error.message)
      end
    end

    test "readiness status returns ok when readiness check is disabled" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => true, "rolbypassrls" => true },
        public_table_ownership_count: 2
      )

      with_environment("DB_ROLE_SECURITY_READY_CHECK_ENABLED" => "false") do
        assert_equal "ok", DatabaseRoleGuard.readiness_status(connection:)
      end
    end

    test "secure? returns false when runtime role owns public tables" do
      connection = FakeConnection.new(
        row: { "role_name" => "nexum_app", "rolsuper" => false, "rolbypassrls" => false },
        public_table_ownership_count: 3
      )

      assert_equal false, DatabaseRoleGuard.secure?(connection:)
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
