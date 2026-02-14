require "digest"

class Rack::Attack
  Rack::Attack.cache.store = Rails.cache

  throttle("web-login/ip", limit: 10, period: 3.minutes) do |request|
    request.ip if request.post? && request.path == "/session"
  end

  throttle("password-reset/ip", limit: 10, period: 3.minutes) do |request|
    request.ip if request.post? && request.path == "/passwords"
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

  self.throttled_responder = lambda do |_request|
    request = Rack::Request.new(_request.env)
    if request.path.start_with?("/api/")
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
end
