require_relative 'boot'
require 'rails/all'

Bundler.require(*Rails.groups)

require_relative "danbooru_default_config"
require_relative "danbooru_local_config"

module Danbooru
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 5.2
    config.active_record.schema_format = :sql
    config.encoding = "utf-8"
    config.filter_parameters += [:password]
    config.assets.enabled = true
    config.assets.version = '1.0'
    config.autoload_paths += %W(#{config.root}/app/presenters #{config.root}/app/logical #{config.root}/app/mailers)
    config.plugins = [:all]
    config.time_zone = 'Eastern Time (US & Canada)'
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {:enable_starttls_auto => false}
    config.action_mailer.perform_deliveries = true
    config.log_tags = [->(req) {"PID:#{Process.pid}"}]
    config.action_controller.action_on_unpermitted_parameters = :raise
    config.force_ssl = true

    if Rails.env.production? && Danbooru.config.ssl_options.present?
      config.ssl_options = Danbooru.config.ssl_options
    else
      config.ssl_options = {
        hsts: false,
        secure_cookies: false,
        redirect: { exclude: ->(request) { true } }
      }
    end

    if File.exists?("#{config.root}/REVISION")
      config.x.git_hash = File.read("#{config.root}/REVISION").strip
    elsif system("type git > /dev/null && git rev-parse --show-toplevel > /dev/null")
      config.x.git_hash = %x(git rev-parse --short HEAD).strip
    else
      config.x.git_hash = nil
    end

    config.after_initialize do
      Rails.application.routes.default_url_options = {
        host: Danbooru.config.hostname,
      }
    end
  end

  I18n.enforce_available_locales = false
end
