require "test_helper"

class DatabaseRequestContextTest < ActiveSupport::TestCase
  test "with applies and clears non-transactional request context including request id" do
    DatabaseRequestContext.with(
      tenant_id: "tenant-test",
      actor_id: "actor-test",
      role: "ops_admin",
      request_id: "request-test",
      local: false
    ) do
      assert_equal "tenant-test", DatabaseRequestContext.current_setting("app.tenant_id")
      assert_equal "actor-test", DatabaseRequestContext.current_setting("app.actor_id")
      assert_equal "ops_admin", DatabaseRequestContext.current_setting("app.role")
      assert_equal "request-test", DatabaseRequestContext.current_setting("app.request_id")
    end

    assert_equal "", DatabaseRequestContext.current_setting("app.tenant_id").to_s
    assert_equal "", DatabaseRequestContext.current_setting("app.actor_id").to_s
    assert_equal "", DatabaseRequestContext.current_setting("app.role").to_s
    assert_equal "", DatabaseRequestContext.current_setting("app.request_id").to_s
  end
end
