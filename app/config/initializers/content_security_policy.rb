Rails.application.configure do
  connect_sources = Array(Rails.app.creds.option(:security, :csp_connect_src, default: ENV["CSP_CONNECT_SRC"]))
                      .flat_map { |value| value.to_s.split(",") }
                      .map(&:strip)
                      .reject(&:blank?)

  img_sources = Array(Rails.app.creds.option(:security, :csp_img_src, default: ENV["CSP_IMG_SRC"]))
                  .flat_map { |value| value.to_s.split(",") }
                  .map(&:strip)
                  .reject(&:blank?)

  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.form_action :self
    policy.frame_ancestors :none
    policy.object_src :none
    policy.script_src :self
    policy.style_src :self
    policy.font_src :self, :data
    policy.img_src(*([ :self, :data, :blob ] + img_sources))
    policy.connect_src(*([ :self ] + connect_sources))
    policy.worker_src :self, :blob
    policy.frame_src :none
    policy.manifest_src :self
    report_uri = Rails.app.creds.option(:security, :csp_report_uri, default: ENV["CSP_REPORT_URI"]).to_s.strip
    policy.report_uri(report_uri) if report_uri.present?
    policy.upgrade_insecure_requests if Rails.env.production?
  end

  # Generate unpredictable per-request nonces for importmap tags and optional inline style/script usage.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
