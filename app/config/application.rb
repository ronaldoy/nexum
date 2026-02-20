require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Nexum
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.2

    # Enforce Fetch Metadata CSRF verification using the Sec-Fetch-Site header.
    config.action_controller.forgery_protection_verification_strategy = :header_only
    config.action_controller.default_protect_from_forgery_with = :exception
    config.middleware.use Rack::Attack

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.time_zone = ENV.fetch("APP_TIMEZONE", "America/Sao_Paulo")
    config.i18n.default_locale = :"pt-BR"
    config.i18n.available_locales = [ :"pt-BR", :en ]
    config.i18n.fallbacks = [ :en ]
    config.active_record.default_timezone = :utc
    config.active_record.schema_format = :sql
    config.beginning_of_week = :monday

    config.x.business_timezone = config.time_zone
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
