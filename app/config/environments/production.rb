require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Use Google Cloud Storage in production by default.
  configured_storage_service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "google")
  if configured_storage_service == "google"
    begin
      require "google/cloud/storage"
    rescue LoadError => error
      raise "google-cloud-storage gem is required for ACTIVE_STORAGE_SERVICE=google: #{error.message}"
    end
  end
  if configured_storage_service == "local"
    raise "ACTIVE_STORAGE_SERVICE=local is not allowed in production."
  end
  config.active_storage.service = configured_storage_service.to_sym

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = ActiveModel::Type::Boolean.new.cast(
    Rails.app.creds.option(:security, :assume_ssl, default: ENV.fetch("RAILS_ASSUME_SSL", true))
  )

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for health endpoints used by infrastructure probes.
  config.ssl_options = {
    redirect: {
      exclude: ->(request) { [ "/up", "/health", "/ready" ].include?(request.path) }
    },
    hsts: {
      expires: 2.years,
      subdomains: true
    }
  }

  # Enforce strict same-site cookie protection globally.
  config.action_dispatch.cookies_same_site_protection = :strict

  # Additional browser hardening headers for financial workloads.
  config.action_dispatch.default_headers.merge!(
    "Permissions-Policy" => "camera=(), geolocation=(), microphone=(), payment=(), usb=()",
    "X-Download-Options" => "noopen"
  )

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  mailer_host = Rails.app.creds.option(:mailer, :host, default: ENV["MAILER_HOST"])
  raise "MAILER_HOST must be configured in production." if mailer_host.blank?
  config.action_mailer.default_url_options = { host: mailer_host, protocol: "https" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  allowed_hosts = Array(Rails.app.creds.option(:security, :allowed_hosts, default: ENV["APP_ALLOWED_HOSTS"]))
                    .flat_map { |value| value.to_s.split(",") }
                    .map(&:strip)
                    .reject(&:blank?)
  config.hosts = allowed_hosts if allowed_hosts.any?

  if allowed_hosts.empty? && ENV["ALLOW_EMPTY_HOSTS"] != "true"
    raise "APP_ALLOWED_HOSTS must be configured in production."
  end
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
