Rails.application.config.after_initialize do
  next unless Rails.env.production?

  row = ActiveRecord::Base.connection.select_one(<<~SQL.squish)
    SELECT r.rolsuper, r.rolbypassrls
    FROM pg_roles r
    WHERE r.rolname = current_user
  SQL

  role_is_superuser = ActiveModel::Type::Boolean.new.cast(row&.fetch("rolsuper", false))
  role_bypasses_rls = ActiveModel::Type::Boolean.new.cast(row&.fetch("rolbypassrls", false))

  if role_is_superuser || role_bypasses_rls
    raise "Database role security violation: application role must not be SUPERUSER or BYPASSRLS."
  end
end
