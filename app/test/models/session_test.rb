require "test_helper"

class SessionTest < ActiveSupport::TestCase
  test "expired? follows configured ttl window" do
    session = users(:one).sessions.create!(tenant: users(:one).tenant, ip_address: "127.0.0.1", user_agent: "test-suite")

    assert_not session.expired?(at: session.created_at + Session.ttl - 1.second)
    assert session.expired?(at: session.created_at + Session.ttl + 1.second)
  end

  test "tenant must match user tenant" do
    assert_raises(ActiveRecord::RecordInvalid) do
      users(:one).sessions.create!(tenant: users(:two).tenant, ip_address: "127.0.0.1", user_agent: "test-suite")
    end
  end
end
