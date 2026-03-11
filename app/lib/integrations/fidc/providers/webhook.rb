require "json"
require "net/http"
require "uri"

module Integrations
  module Fidc
    module Providers
      class Webhook < Base
        DEFAULT_OPEN_TIMEOUT_SECONDS = 3
        DEFAULT_READ_TIMEOUT_SECONDS = 10

        def provider_code
          "WEBHOOK"
        end

        def request_funding!(tenant_id:, anticipation_request:, payload:, idempotency_key:)
          body = payload.merge(
            "operation" => "funding_request",
            "request_control_key" => idempotency_key,
            "tenant_id" => tenant_id,
            "anticipation_request_id" => anticipation_request.id
          )
          dispatch!(path: funding_path, body: body)
        end

        def report_settlement!(tenant_id:, settlement:, payload:, idempotency_key:)
          body = payload.merge(
            "operation" => "settlement_report",
            "request_control_key" => idempotency_key,
            "tenant_id" => tenant_id,
            "receivable_payment_settlement_id" => settlement.id
          )
          dispatch!(path: settlement_path, body: body)
        end

        private

        def dispatch!(path:, body:)
          uri = build_uri(path)
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          request["Idempotency-Key"] = body.fetch("request_control_key")
          request["Authorization"] = "Bearer #{configured_bearer_token}"
          request.body = JSON.generate(body)

          response = nil
          Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: open_timeout_seconds,
            read_timeout: read_timeout_seconds
          ) do |http|
            response = http.request(request)
          end

          parsed_body = parse_response_body(response.body)
          status = map_status(response.code.to_i)
          if status == "FAILED"
            raise RemoteError.new(
              code: "fidc_webhook_http_error",
              message: "FIDC webhook provider returned non-success response.",
              http_status: response.code.to_i,
              details: {
                response_code: response.code.to_i,
                response_body: parsed_body
              }
            )
          end

          OperationResult.new(
            provider_reference: parsed_body["provider_reference"].presence || parsed_body["operation_id"].presence || request["Idempotency-Key"],
            status: status,
            metadata: {
              "http_status" => response.code.to_i,
              "response_body" => parsed_body
            }
          )
        rescue SocketError, SystemCallError, Timeout::Error, IOError => error
          raise RemoteError.new(
            code: "fidc_webhook_unreachable",
            message: "FIDC webhook endpoint is unreachable.",
            http_status: 503,
            details: { error_class: error.class.name, error_message: error.message }
          )
        end

        def build_uri(path)
          base = base_uri
          URI.join(base_uri_for_join(base), path.sub(%r{^/}, ""))
        rescue URI::InvalidURIError => error
          raise ConfigurationError.new(
            code: "fidc_webhook_base_url_invalid",
            message: "FIDC webhook base URL is invalid.",
            details: { error_message: error.message }
          )
        end

        def parse_response_body(raw_body)
          return {} if raw_body.to_s.strip.blank?

          parsed = JSON.parse(raw_body)
          return parsed if parsed.is_a?(Hash)

          { "raw" => parsed }
        rescue JSON::ParserError
          { "raw" => raw_body.to_s }
        end

        def map_status(http_status)
          return "SENT" if (200..299).cover?(http_status)

          "FAILED"
        end

        def base_url
          value = Rails.app.creds.option(:integrations, :fidc, :webhook, :base_url, default: ENV["FIDC_WEBHOOK_BASE_URL"]).to_s.strip
          if value.blank?
            raise ConfigurationError.new(
              code: "fidc_webhook_base_url_missing",
              message: "FIDC webhook base URL is missing."
            )
          end

          value
        end

        def base_uri
          @base_uri ||= begin
            uri = URI.parse(base_url)
            validate_base_uri!(uri)
            uri
          end
        rescue URI::InvalidURIError => error
          raise ConfigurationError.new(
            code: "fidc_webhook_base_url_invalid",
            message: "FIDC webhook base URL is invalid.",
            details: { error_message: error.message }
          )
        end

        def validate_base_uri!(uri)
          invalid_reasons = []
          invalid_reasons << "must use HTTPS" unless uri.is_a?(URI::HTTPS)
          invalid_reasons << "must include host" if uri.host.to_s.blank?
          invalid_reasons << "must not include userinfo" if uri.userinfo.present?
          invalid_reasons << "must not include query parameters" if uri.query.present?
          invalid_reasons << "must not include fragments" if uri.fragment.present?
          return if invalid_reasons.empty?

          raise ConfigurationError.new(
            code: "fidc_webhook_base_url_invalid",
            message: "FIDC webhook base URL is invalid.",
            details: { reason: invalid_reasons.join(", ") }
          )
        end

        def base_uri_for_join(uri)
          normalized = uri.dup
          normalized.path = "/" if normalized.path.to_s.blank?
          text = normalized.to_s
          text.end_with?("/") ? text : "#{text}/"
        end

        def funding_path
          Rails.app.creds.option(:integrations, :fidc, :webhook, :funding_path, default: ENV["FIDC_WEBHOOK_FUNDING_PATH"].presence || "/funding_requests").to_s
        end

        def settlement_path
          Rails.app.creds.option(:integrations, :fidc, :webhook, :settlement_path, default: ENV["FIDC_WEBHOOK_SETTLEMENT_PATH"].presence || "/settlement_reports").to_s
        end

        def configured_bearer_token
          token = Rails.app.creds.option(
            :integrations,
            :fidc,
            :webhook,
            :bearer_token,
            default: ENV["FIDC_WEBHOOK_BEARER_TOKEN"]
          ).to_s.strip
          return token if token.present?

          raise ConfigurationError.new(
            code: "fidc_webhook_bearer_token_missing",
            message: "FIDC webhook bearer token is missing."
          )
        end

        def open_timeout_seconds
          value = Rails.app.creds.option(
            :integrations,
            :fidc,
            :webhook,
            :open_timeout_seconds,
            default: ENV["FIDC_WEBHOOK_OPEN_TIMEOUT_SECONDS"]
          )
          Integer(value, exception: false) || DEFAULT_OPEN_TIMEOUT_SECONDS
        end

        def read_timeout_seconds
          value = Rails.app.creds.option(
            :integrations,
            :fidc,
            :webhook,
            :read_timeout_seconds,
            default: ENV["FIDC_WEBHOOK_READ_TIMEOUT_SECONDS"]
          )
          Integer(value, exception: false) || DEFAULT_READ_TIMEOUT_SECONDS
        end
      end
    end
  end
end
