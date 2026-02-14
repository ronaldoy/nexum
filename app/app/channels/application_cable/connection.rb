module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_session
    before_command :ensure_current_session_valid!

    def connect
      establish_current_session || reject_unauthorized_connection
    end

    private
      def establish_current_session
        session = load_session_from_cookies
        return unless valid_session?(session)

        self.current_session = session
        self.current_user = session.user
      end

      def ensure_current_session_valid!
        session = load_session_from_cookies
        reject_unauthorized_connection unless valid_session?(session)

        self.current_session = session
        self.current_user = session.user
      end

      def load_session_from_cookies
        session_id = cookies.encrypted[:session_id]
        tenant_id = cookies.encrypted[:session_tenant_id]
        return nil if session_id.blank? || tenant_id.blank?

        with_database_tenant_context(tenant_id) do
          Session.find_by(id: session_id, tenant_id: tenant_id)
        end
      end

      def valid_session?(session)
        return false if session.blank?
        return false if session.user.blank?
        return false if session.user.tenant_id.to_s != session.tenant_id.to_s

        if session.expired?
          session.destroy
          return false
        end

        return false if session.ip_address.present? && session.ip_address != request.remote_ip
        return false if session.user_agent.present? && session.user_agent != request.user_agent.to_s

        true
      end

      def with_database_tenant_context(tenant_id)
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction(requires_new: true) do
            connection = ActiveRecord::Base.connection
            connection.execute(
              "SELECT set_config(#{connection.quote('app.tenant_id')}, #{connection.quote(tenant_id.to_s)}, true)"
            )
            yield
          end
        end
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
        nil
      end
  end
end
