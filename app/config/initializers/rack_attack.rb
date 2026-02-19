require "digest"

class Rack::Attack
  Rack::Attack.cache.store = Rails.cache

  throttle("web-login/ip", limit: 10, period: 3.minutes) do |request|
    request.ip if web_login_request?(request)
  end

  throttle("web-login/account", limit: 8, period: 10.minutes) do |request|
    account_throttle_key(request, path: "/session")
  end

  throttle("password-reset/ip", limit: 10, period: 3.minutes) do |request|
    request.ip if password_reset_request?(request)
  end

  throttle("password-reset/account", limit: 6, period: 10.minutes) do |request|
    account_throttle_key(request, path: "/passwords")
  end

  throttle("api-mutation/ip", limit: 300, period: 5.minutes) do |request|
    request.ip if api_mutation_request?(request)
  end

  throttle("api-mutation/token", limit: 180, period: 1.minute) do |request|
    next unless api_mutation_request?(request)

    authorization = request.get_header("HTTP_AUTHORIZATION").to_s
    next if authorization.blank?

    Digest::SHA256.hexdigest(authorization)
  end

  throttle("api-confirmation/ip", limit: 25, period: 5.minutes) do |request|
    next unless request.post?
    next unless request.path.match?(%r{\A/api/v1/(anticipation_requests|receivables)/[^/]+/(confirm|attach_document)\z})

    request.ip
  end

  throttle("direct-upload/ip", limit: 60, period: 5.minutes) do |request|
    request.ip if direct_upload_request?(request)
  end

  throttle("direct-upload/actor", limit: 90, period: 5.minutes) do |request|
    next unless direct_upload_request?(request)

    authorization = request.get_header("HTTP_AUTHORIZATION").to_s
    if authorization.present?
      "token:#{Digest::SHA256.hexdigest(authorization)}"
    else
      tenant_cookie = request.cookies["session_tenant_id"].to_s
      session_cookie = request.cookies["session_id"].to_s
      next if tenant_cookie.blank? || session_cookie.blank?

      "session:#{Digest::SHA256.hexdigest("#{tenant_cookie}:#{session_cookie}")}"
    end
  end

  throttle("openapi-docs/ip", limit: 40, period: 10.minutes) do |request|
    request.ip if openapi_docs_request?(request)
  end

  throttle("openapi-docs/credential", limit: 20, period: 10.minutes) do |request|
    next unless openapi_docs_request?(request)

    authorization = request.get_header("HTTP_AUTHORIZATION").to_s
    fingerprint = authorization.present? ? Digest::SHA256.hexdigest(authorization) : "missing"

    "#{request.ip}:#{fingerprint}"
  end

  self.throttled_responder = lambda do |_request|
    request = Rack::Request.new(_request.env)
    if request.path.start_with?("/api/") || Rack::Attack.openapi_docs_request?(request)
      [
        429,
        { "Content-Type" => "application/json" },
        [ { error: { code: "rate_limited", message: "Too many requests." } }.to_json ]
      ]
    else
      [ 429, { "Content-Type" => "text/plain" }, [ "Too many requests." ] ]
    end
  end

  def self.api_mutation_request?(request)
    request.path.start_with?("/api/") && !request.get? && !request.head?
  end

  def self.direct_upload_request?(request)
    request.post? && request.path == "/rails/active_storage/direct_uploads"
  end

  def self.web_login_request?(request)
    request.post? && request.path == "/session"
  end

  def self.password_reset_request?(request)
    request.post? && request.path == "/passwords"
  end

  def self.openapi_docs_request?(request)
    request.path == "/docs/openapi/v1" || request.path == "/docs/openapi/v1.yaml"
  end

  def self.account_throttle_key(request, path:)
    return nil unless request.post? && request.path == path

    tenant_slug = normalized_request_param(request, "tenant_slug")
    email_address = normalized_request_param(request, "email_address")
    return nil if tenant_slug.blank? || email_address.blank?

    "#{tenant_slug}:#{Digest::SHA256.hexdigest(email_address)}"
  end

  def self.normalized_request_param(request, key)
    request.params[key].to_s.strip.downcase.presence
  rescue StandardError
    nil
  end
end
