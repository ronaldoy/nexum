require "test_helper"

module Security
  class DatabaseSchemaAuditTest < ActiveSupport::TestCase
    test "test database satisfies schema audit" do
      assert_equal true, DatabaseSchemaAudit.secure?
      assert_equal [], DatabaseSchemaAudit.violations
      assert_equal "ok", DatabaseSchemaAudit.readiness_status
    end
  end
end
