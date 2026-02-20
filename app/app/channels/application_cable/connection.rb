module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_session, :current_tenant_id, :current_actor_id, :current_role
    around_command :with_database_request_context

    def connect
      establish_current_session || reject_unauthorized_connection
    end

    private
      def establish_current_session
        session = load_session_from_cookies
        return unless valid_session?(session)

        set_current_identity!(session)
      end

      def ensure_current_session_valid!
        session = load_session_from_cookies
        reject_unauthorized_connection unless valid_session?(session)

        set_current_identity!(session)
      end

      def set_current_identity!(session)
        user = session.user
        self.current_session = session
        self.current_user = user
        self.current_tenant_id = session.tenant_id.to_s
        self.current_actor_id = user&.party_id || user&.uuid_id || user&.id
        self.current_role = user&.role.to_s
      end

      def with_database_request_context
        ensure_current_session_valid!
        reject_unauthorized_connection if current_tenant_id.blank?

        with_database_context(
          tenant_id: current_tenant_id,
          actor_id: current_actor_id,
          role: current_role
        ) do
          Current.set(
            session: current_session,
            user: current_user,
            tenant_id: current_tenant_id,
            actor_id: current_actor_id,
            role: current_role
          ) do
            yield
          end
        end
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid => error
        Rails.logger.error(
          "websocket_request_context_failure tenant_id=#{current_tenant_id} " \
          "error_class=#{error.class.name} error_message=#{error.message}"
        )
        reject_unauthorized_connection
      ensure
        Current.reset
      end

      def load_session_from_cookies
        session_id = cookies.encrypted[:session_id]
        tenant_id = cookies.encrypted[:session_tenant_id]
        return nil if session_id.blank? || tenant_id.blank?

        with_database_tenant_context(tenant_id) do
          Session.includes(:user).find_by(id: session_id, tenant_id: tenant_id)
        end
      end

      def valid_session?(session)
        return false if session.blank?
        user = session.user
        return false if user.blank?
        return false if user.tenant_id.to_s != session.tenant_id.to_s

        if session.expired?
          session.destroy
          return false
        end

        return false if session.ip_address.present? && enforce_websocket_ip_binding? && session.ip_address != request.remote_ip
        return false if session.user_agent.present? && session.user_agent != request.user_agent.to_s

        true
      end

      def enforce_websocket_ip_binding?
        configured = Rails.app.creds.option(:security, :websocket_bind_ip, default: ENV["WEBSOCKET_BIND_IP"])
        return ActiveModel::Type::Boolean.new.cast(configured) unless configured.nil?

        true
      end

      def with_database_tenant_context(tenant_id, actor_id: nil, role: nil)
        with_database_context(tenant_id:, actor_id:, role:) do
          yield
        end
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid => error
        Rails.logger.error(
          "websocket_tenant_context_failure tenant_id=#{tenant_id} " \
          "error_class=#{error.class.name} error_message=#{error.message}"
        )
        nil
      end

      def with_database_context(tenant_id:, actor_id: nil, role: nil)
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction(requires_new: true) do
            set_database_context!("app.tenant_id", tenant_id)
            set_database_context!("app.actor_id", actor_id)
            set_database_context!("app.role", role)
            yield
          end
        end
      end

      def set_database_context!(key, value)
        connection = ActiveRecord::Base.connection
        connection.execute(
          "SELECT set_config(#{connection.quote(key.to_s)}, #{connection.quote(value.to_s)}, true)"
        )
      end
  end
end
