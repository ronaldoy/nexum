# WARNING: Change the default password before deploying to production!
# Set the ADMIN_PASSWORD environment variable or update the credentials below.

admin_username = ENV.fetch("ADMIN_USERNAME", "admin")
admin_password = ENV.fetch("ADMIN_PASSWORD", Rails.env.local? ? "upright" : nil)

if Rails.env.production? && (admin_password.blank? || admin_password == "upright")
  raise "Set ADMIN_PASSWORD to a non-default value in production."
end

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :static_credentials,
    title: "Sign In",
    credentials: { admin_username => admin_password.presence || "upright" }
end
