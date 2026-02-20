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
      session_id = cookies.encrypted[:session_id]
      tenant_id = cookies.encrypted[SESSION_TENANT_COOKIE_KEY]
      user_uuid_id = cookies.encrypted[SESSION_USER_UUID_COOKIE_KEY]
      return unless session_id && tenant_id

      bootstrap_database_tenant_context!(tenant_id)

      session = Session.includes(:user).find_by(id: session_id, tenant_id: tenant_id)
      unless session
        clear_bootstrap_database_tenant_context!
        return nil
      end

      user = session.user
      unless user&.tenant_id.to_s == tenant_id.to_s
        terminate_persisted_session(session)
        clear_bootstrap_database_tenant_context!
        return nil
      end

      if user_uuid_id.present? && user.uuid_id.to_s != user_uuid_id.to_s
        terminate_persisted_session(session)
        clear_bootstrap_database_tenant_context!
        return nil
      end

      unless valid_session_fingerprint?(session)
        terminate_persisted_session(session)
        clear_bootstrap_database_tenant_context!
        return nil
      end

      return session unless session.expired?

      terminate_persisted_session(session)
      clear_bootstrap_database_tenant_context!
      nil
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def start_new_session_for(user)
      reset_session

      user.sessions.create!(tenant: user.tenant, user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        Current.user = user
        cookies.encrypted[:session_id] = {
          value: session.id,
          **session_cookie_options
        }
        cookies.encrypted[SESSION_TENANT_COOKIE_KEY] = {
          value: session.tenant_id,
          **session_cookie_options
        }
        cookies.encrypted[SESSION_USER_UUID_COOKIE_KEY] = {
          value: user.uuid_id,
          **session_cookie_options
        }
      end
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
