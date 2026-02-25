module Authentication
  extend ActiveSupport::Concern

  SESSION_TENANT_COOKIE_KEY = :session_tenant_id
  SESSION_USER_UUID_COOKIE_KEY = :session_user_uuid_id

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
  def authenticated?
    resume_session
  end

  def require_authentication
    resume_session || request_authentication
  end

  def resume_session
    Current.session ||= find_session_by_cookie
    Current.user ||= Current.session&.user
  end

  def find_session_by_cookie
    cookie_identity = session_cookie_identity
    return unless valid_session_cookie_identity?(cookie_identity)

    bootstrap_database_tenant_context!(cookie_identity[:tenant_id])
    session = find_persisted_session(cookie_identity)
    return clear_bootstrap_database_tenant_context! && nil unless session

    return reject_persisted_session(session) unless valid_session_user_tenant?(session, cookie_identity[:tenant_id])
    return reject_persisted_session(session) if invalid_session_user_uuid?(session, cookie_identity[:user_uuid_id])
    return reject_persisted_session(session) unless valid_session_fingerprint?(session)
    return reject_persisted_session(session) if session.expired?

    session
  end

  def session_cookie_identity
    {
      session_id: cookies.encrypted[:session_id],
      tenant_id: cookies.encrypted[SESSION_TENANT_COOKIE_KEY],
      user_uuid_id: cookies.encrypted[SESSION_USER_UUID_COOKIE_KEY]
    }
  end

  def valid_session_cookie_identity?(cookie_identity)
    cookie_identity[:session_id].present? && cookie_identity[:tenant_id].present?
  end

  def find_persisted_session(cookie_identity)
    Session.includes(:user).find_by(id: cookie_identity[:session_id], tenant_id: cookie_identity[:tenant_id])
  end

  def valid_session_user_tenant?(session, tenant_id)
    session.user&.tenant_id.to_s == tenant_id.to_s
  end

  def invalid_session_user_uuid?(session, user_uuid_id)
    user_uuid_id.present? && session.user.uuid_id.to_s != user_uuid_id.to_s
  end

  def reject_persisted_session(session)
    terminate_persisted_session(session)
    clear_bootstrap_database_tenant_context!
    nil
  end

  def request_authentication
    session[:return_to_after_authenticating] = safe_return_to_path(request.fullpath)
    redirect_to new_session_path
  end

  def after_authentication_url
    safe_return_to_path(session.delete(:return_to_after_authenticating)) || root_path
  end

  def safe_return_to_path(value)
    path = value.to_s
    return nil if path.blank?
    return nil if path.start_with?("//")
    return nil unless path.start_with?("/")

    path
  end

  def start_new_session_for(user)
    reset_session

    user.sessions.create!(tenant: user.tenant, user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
      Current.session = session
      Current.user = user
      assign_session_cookies(session:, user:)
    end
  end

  def assign_session_cookies(session:, user:)
    write_encrypted_session_cookie(:session_id, session.id)
    write_encrypted_session_cookie(SESSION_TENANT_COOKIE_KEY, session.tenant_id)
    write_encrypted_session_cookie(SESSION_USER_UUID_COOKIE_KEY, user.uuid_id)
  end

  def write_encrypted_session_cookie(key, value)
    cookies.encrypted[key] = { value: value, **session_cookie_options }
  end

  def terminate_session
    terminate_persisted_session(Current.session)
    Current.session = nil
    Current.user = nil
    clear_session_cookies
    clear_bootstrap_database_tenant_context!
  end

  def terminate_persisted_session(session)
    session&.destroy
    clear_session_cookies
  end

  def clear_session_cookies
    cookies.delete(:session_id)
    cookies.delete(SESSION_TENANT_COOKIE_KEY)
    cookies.delete(SESSION_USER_UUID_COOKIE_KEY)
  end

  def session_cookie_options
    {
      expires: Session.ttl.from_now,
      httponly: true,
      secure: secure_session_cookies?,
      same_site: :strict
    }
  end

  def secure_session_cookies?
    configured = Rails.app.creds.option(:security, :secure_session_cookies, default: ENV["SECURE_SESSION_COOKIES"])
    return ActiveModel::Type::Boolean.new.cast(configured) unless configured.nil?

    !Rails.env.development? && !Rails.env.test?
  end

  def valid_session_fingerprint?(session)
    return false if session.blank?
    return false if session.ip_address.present? && enforce_session_ip_binding? && session.ip_address != request.remote_ip
    return false if session.user_agent.present? && enforce_session_user_agent_binding? && session.user_agent != request.user_agent.to_s

    true
  end

  def enforce_session_ip_binding?
    configured = Rails.app.creds.option(:security, :session_bind_ip, default: ENV["SESSION_BIND_IP"])
    return ActiveModel::Type::Boolean.new.cast(configured) unless configured.nil?

    true
  end

  def enforce_session_user_agent_binding?
    configured = Rails.app.creds.option(:security, :session_bind_user_agent, default: ENV["SESSION_BIND_USER_AGENT"])
    return ActiveModel::Type::Boolean.new.cast(configured) unless configured.nil?

    true
  end
end
