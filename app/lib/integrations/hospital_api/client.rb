require "json"
require "net/http"
require "uri"

module Integrations
  module HospitalApi
    class Client
      def initialize(base_url:, bearer_token:, open_timeout: 3, read_timeout: 10)
        @base_uri = parse_and_validate_base_uri!(base_url)
        @bearer_token = bearer_token.to_s.strip
        @open_timeout = open_timeout.to_i
        @read_timeout = read_timeout.to_i

        if @bearer_token.blank?
          raise ConfigurationError.new(
            code: "hospital_api_bearer_token_missing",
            message: "Hospital API bearer token is missing."
          )
        end
      end

      def upsert_payment_instructions!(path:, body:, idempotency_key:)
        uri = build_uri(path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request["Authorization"] = "Bearer #{@bearer_token}"
        request["Idempotency-Key"] = idempotency_key
        request["X-Request-Id"] = idempotency_key
        request.body = JSON.generate(body)

        response = nil
        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: @open_timeout,
          read_timeout: @read_timeout
        ) do |http|
          response = http.request(request)
        end

        parsed_body = parse_response_body(response.body)
        return {
          "http_status" => response.code.to_i,
          "response_body" => parsed_body
        } if response.code.to_i.between?(200, 299)

        raise RemoteError.new(
          code: "hospital_api_http_error",
          message: "Hospital API returned a non-success response.",
          http_status: response.code.to_i,
          details: {
            endpoint: uri.path,
            response_code: response.code.to_i,
            response_body: parsed_body
          }
        )
      rescue JSON::GeneratorError => error
        raise ValidationError.new(
          code: "hospital_api_payload_invalid",
          message: "Invalid payload for Hospital API request.",
          details: { error: error.message }
        )
      rescue SocketError, SystemCallError, Timeout::Error, IOError => error
        raise RemoteError.new(
          code: "hospital_api_unreachable",
          message: "Hospital API endpoint is unreachable.",
          http_status: 503,
          details: { error_class: error.class.name, error_message: error.message }
        )
      end

      private

      def build_uri(path)
        endpoint = path.to_s
        endpoint = "/#{endpoint}" unless endpoint.start_with?("/")

        uri = @base_uri.dup
        base_path = uri.path.to_s.sub(%r{/\z}, "")
        uri.path = [ base_path, endpoint ].join
        uri.query = nil
        uri.fragment = nil
        uri
      end

      def parse_response_body(raw_body)
        return {} if raw_body.to_s.strip.blank?

        parsed = JSON.parse(raw_body)
        parsed.is_a?(Hash) ? parsed : { "raw" => parsed }
      rescue JSON::ParserError
        { "raw" => raw_body.to_s }
      end

      def parse_and_validate_base_uri!(value)
        uri = URI.parse(value.to_s)
        invalid_reasons = []
        invalid_reasons << "must use HTTPS" unless uri.is_a?(URI::HTTPS)
        invalid_reasons << "must include host" if uri.host.to_s.blank?
        invalid_reasons << "must not include userinfo" if uri.userinfo.present?
        invalid_reasons << "must not include query parameters" if uri.query.present?
        invalid_reasons << "must not include fragments" if uri.fragment.present?
        return uri if invalid_reasons.empty?

        raise ConfigurationError.new(
          code: "hospital_api_base_url_invalid",
          message: "Hospital API base URL is invalid.",
          details: { reason: invalid_reasons.join(", ") }
        )
      rescue URI::InvalidURIError => error
        raise ConfigurationError.new(
          code: "hospital_api_base_url_invalid",
          message: "Hospital API base URL is invalid.",
          details: { error_message: error.message }
        )
      end
    end
  end
end
