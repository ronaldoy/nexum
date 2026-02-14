module SessionTestHelper
  def sign_in_as(user)
    Current.session = user.sessions.create!(tenant: user.tenant)
    Current.user = user

    ActionDispatch::TestRequest.create.cookie_jar.tap do |cookie_jar|
      cookie_jar.encrypted[:session_id] = Current.session.id
      cookie_jar.encrypted[:session_tenant_id] = user.tenant_id
      cookies["session_id"] = cookie_jar[:session_id]
      cookies["session_tenant_id"] = cookie_jar[:session_tenant_id]
    end
  end

  def sign_out
    Current.session&.destroy!
    Current.user = nil
    cookies.delete("session_id")
    cookies.delete("session_tenant_id")
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include SessionTestHelper
end
