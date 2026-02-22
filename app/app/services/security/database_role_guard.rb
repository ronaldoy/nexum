module Security
  class DatabaseRoleGuard
    VIOLATION_MESSAGE = "Database role security violation: application role must not be SUPERUSER or BYPASSRLS.".freeze

    class << self
      def ensure_secure!(connection: ActiveRecord::Base.connection)
        return true unless enforce_on_boot?
        return true if allow_insecure_role?
        return true if secure?(connection:)

        raise VIOLATION_MESSAGE
      end

      def readiness_status(connection: ActiveRecord::Base.connection)
        return "ok" unless enforce_readiness?
        return "ok" if allow_insecure_role?

        secure?(connection:) ? "ok" : "error"
      rescue PG::Error, ActiveRecord::ActiveRecordError => error
        Rails.logger.error("database_role_security_check_failed error_class=#{error.class} message=#{error.message}")
        "error"
      end

      def secure?(connection: ActiveRecord::Base.connection)
        flags = role_flags(connection:)
        !flags.fetch(:role_is_superuser) && !flags.fetch(:role_bypasses_rls)
      end

      def role_flags(connection: ActiveRecord::Base.connection)
        row = connection.select_one(<<~SQL.squish)
          SELECT current_user AS role_name, r.rolsuper, r.rolbypassrls
          FROM pg_roles r
          WHERE r.rolname = current_user
        SQL

        {
          role_name: row&.fetch("role_name", current_role_name(connection:)),
          role_is_superuser: boolean_cast(row&.fetch("rolsuper", false)),
          role_bypasses_rls: boolean_cast(row&.fetch("rolbypassrls", false))
        }
      end

      def enforce_on_boot?
        boolean_env("DB_ROLE_SECURITY_ENFORCED", default: Rails.env.production?)
      end

      def enforce_readiness?
        boolean_env("DB_ROLE_SECURITY_READY_CHECK_ENABLED", default: enforce_on_boot?)
      end

      def allow_insecure_role?
        boolean_env("DB_ROLE_SECURITY_ALLOW_INSECURE", default: false)
      end

      private

      def current_role_name(connection:)
        connection.select_value("SELECT current_user")
      rescue PG::Error, ActiveRecord::ActiveRecordError
        nil
      end

      def boolean_env(key, default:)
        boolean_cast(ENV.fetch(key, default.to_s))
      end

      def boolean_cast(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end
    end
  end
end
