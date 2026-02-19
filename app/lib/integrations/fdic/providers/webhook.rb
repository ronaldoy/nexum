require "json"
require "net/http"
require "uri"

module Integrations
  module Fdic
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
          request["Authorization"] = "Bearer #{bearer_token}" if bearer_token.present?
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
              code: "fdic_webhook_http_error",
              message: "FDIC webhook provider returned non-success response.",
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
            code: "fdic_webhook_unreachable",
            message: "FDIC webhook endpoint is unreachable.",
            http_status: 503,
            details: { error_class: error.class.name, error_message: error.message }
          )
        end

        def build_uri(path)
          base = base_url
          URI.join("#{base.end_with?("/") ? base : "#{base}/"}", path.sub(%r{^/}, ""))
        rescue URI::InvalidURIError => error
          raise ConfigurationError.new(
            code: "fdic_webhook_base_url_invalid",
            message: "FDIC webhook base URL is invalid.",
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
          value = Rails.app.creds.option(:integrations, :fdic, :webhook, :base_url, default: ENV["FDIC_WEBHOOK_BASE_URL"]).to_s.strip
          if value.blank?
            raise ConfigurationError.new(
              code: "fdic_webhook_base_url_missing",
              message: "FDIC webhook base URL is missing."
            )
          end

          value
        end

        def funding_path
          Rails.app.creds.option(:integrations, :fdic, :webhook, :funding_path, default: ENV["FDIC_WEBHOOK_FUNDING_PATH"].presence || "/funding_requests").to_s
        end

        def settlement_path
          Rails.app.creds.option(:integrations, :fdic, :webhook, :settlement_path, default: ENV["FDIC_WEBHOOK_SETTLEMENT_PATH"].presence || "/settlement_reports").to_s
        end

        def bearer_token
          Rails.app.creds.option(:integrations, :fdic, :webhook, :bearer_token, default: ENV["FDIC_WEBHOOK_BEARER_TOKEN"]).to_s.strip.presence
        end

        def open_timeout_seconds
          value = Rails.app.creds.option(
            :integrations,
            :fdic,
            :webhook,
            :open_timeout_seconds,
            default: ENV["FDIC_WEBHOOK_OPEN_TIMEOUT_SECONDS"]
          )
          Integer(value, exception: false) || DEFAULT_OPEN_TIMEOUT_SECONDS
        end

        def read_timeout_seconds
          value = Rails.app.creds.option(
            :integrations,
            :fdic,
            :webhook,
            :read_timeout_seconds,
            default: ENV["FDIC_WEBHOOK_READ_TIMEOUT_SECONDS"]
          )
          Integer(value, exception: false) || DEFAULT_READ_TIMEOUT_SECONDS
        end
      end
    end
  end
end
