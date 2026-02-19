require "json"
require "net/http"
require "uri"

module Integrations
  module Escrow
    module Providers
      class QiTech
        class Client
          def initialize(base_url:, api_client_key:, signer:, open_timeout: 10, read_timeout: 30)
            @base_uri = URI.parse(base_url)
            @api_client_key = api_client_key.to_s.strip
            @signer = signer
            @open_timeout = open_timeout.to_i
            @read_timeout = read_timeout.to_i

            if @api_client_key.blank?
              raise ConfigurationError.new(
                code: "qitech_api_client_key_missing",
                message: "QI Tech API client key is missing."
              )
            end
          end

          def post(path:, body:)
            request!(method: "POST", path: path, body: body)
          end

          def patch(path:, body:)
            request!(method: "PATCH", path: path, body: body)
          end

          private

          def request!(method:, path:, body:)
            serialized_body = JSON.generate(body)
            token = @signer.sign(method: method, uri: path, body: serialized_body)
            uri = build_uri(path)

            request = request_class(method).new(uri)
            request["Content-Type"] = "application/json"
            request["Accept"] = "application/json"
            request["API-CLIENT-KEY"] = @api_client_key
            request["Authorization"] = token
            request["AUTHORIZATION"] = token
            request.body = serialized_body

            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            http.open_timeout = @open_timeout
            http.read_timeout = @read_timeout

            response = http.request(request)
            parsed = parse_json(response.body)

            return parsed if response.code.to_i.between?(200, 299)

            raise RemoteError.new(
              code: parsed.dig("error", "code").presence || parsed["code"].presence || "qitech_http_error",
              message: parsed.dig("error", "message").presence || parsed["message"].presence || "QI Tech request failed.",
              http_status: response.code.to_i,
              details: {
                endpoint: path,
                http_status: response.code.to_i,
                response_body: parsed.presence || response.body
              }
            )
          rescue JSON::GeneratorError => error
            raise ValidationError.new(
              code: "qitech_payload_invalid",
              message: "Invalid payload for QI Tech request.",
              details: { error: error.message }
            )
          end

          def build_uri(path)
            endpoint = path.to_s
            endpoint = "/#{endpoint}" unless endpoint.start_with?("/")

            uri = @base_uri.dup
            base_path = uri.path.to_s.sub(%r{/\z}, "")
            combined_path = [ base_path, endpoint ].join
            uri.path = combined_path
            uri.query = nil
            uri.fragment = nil
            uri
          end

          def parse_json(raw_body)
            body = raw_body.to_s
            return {} if body.blank?

            JSON.parse(body)
          rescue JSON::ParserError
            {}
          end

          def request_class(method)
            case method.to_s.upcase
            when "POST"
              Net::HTTP::Post
            when "PATCH"
              Net::HTTP::Patch
            else
              raise ArgumentError, "Unsupported HTTP method #{method.inspect}"
            end
          end
        end
      end
    end
  end
end
