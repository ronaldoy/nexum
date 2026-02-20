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

  test "syncs user_uuid_id when session is created from user association" do
    user = users(:one)

    session = user.sessions.create!(
      tenant: user.tenant,
      ip_address: "127.0.0.1",
      user_agent: "test-suite"
    )

    assert_equal user.uuid_id, session.user_uuid_id
  end

  test "resolves user from user_uuid_id" do
    user = users(:one)
    session = Session.new(
      tenant: user.tenant,
      user_uuid_id: user.uuid_id,
      ip_address: "127.0.0.1",
      user_agent: "test-suite"
    )

    assert session.valid?
    assert_equal user.uuid_id, session.user_uuid_id
    assert_equal user, session.user
  end
end
