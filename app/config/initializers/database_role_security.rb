Rails.application.config.after_initialize do
  Security::DatabaseRoleGuard.ensure_secure!
end
