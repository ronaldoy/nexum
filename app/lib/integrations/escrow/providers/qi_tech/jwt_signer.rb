require "base64"
require "digest/md5"
require "json"
require "openssl"

module Integrations
  module Escrow
    module Providers
      class QiTech
        class JwtSigner
          ES512_COORDINATE_BYTES = 66

          def initialize(api_client_key:, private_key_pem:, key_id: nil, clock: -> { Time.current })
            @api_client_key = api_client_key.to_s.strip
            @private_key = load_private_key(private_key_pem)
            @key_id = key_id.to_s.strip
            @clock = clock

            if @api_client_key.blank?
              raise ConfigurationError.new(
                code: "qitech_api_client_key_missing",
                message: "QI Tech API client key is missing."
              )
            end
          end

          def sign(method:, uri:, body:)
            timestamp = @clock.call.utc.iso8601(6)

            payload = {
              "payload_md5" => payload_md5(body),
              "timestamp" => timestamp,
              "method" => method.to_s.upcase,
              "uri" => uri.to_s,
              "iss" => @api_client_key
            }
            header = {
              "alg" => "ES512",
              "typ" => "JWT"
            }
            header["kid"] = @key_id if @key_id.present?

            encoded_header = base64url(JSON.generate(header))
            encoded_payload = base64url(JSON.generate(payload))
            signing_input = "#{encoded_header}.#{encoded_payload}"

            signature = @private_key.dsa_sign_asn1(OpenSSL::Digest::SHA512.digest(signing_input))
            encoded_signature = base64url(der_signature_to_jose(signature))

            "#{signing_input}.#{encoded_signature}"
          end

          private

          def load_private_key(raw_key)
            pem = raw_key.to_s
            key = OpenSSL::PKey.read(pem)
            return key if key.is_a?(OpenSSL::PKey::EC)

            raise ConfigurationError.new(
              code: "qitech_private_key_invalid",
              message: "QI Tech private key must be an EC key for ES512 signing."
            )
          rescue OpenSSL::PKey::PKeyError => error
            raise ConfigurationError.new(
              code: "qitech_private_key_invalid",
              message: "QI Tech private key is invalid.",
              details: { error: error.message }
            )
          end

          def payload_md5(body)
            Base64.strict_encode64(Digest::MD5.digest(body.to_s))
          end

          def der_signature_to_jose(der_signature)
            sequence = OpenSSL::ASN1.decode(der_signature)
            r = sequence.value[0].value.to_i
            s = sequence.value[1].value.to_i

            [ r, s ].map { |value| encode_coordinate(value) }.join
          end

          def encode_coordinate(value)
            hex = value.to_s(16)
            hex = "0#{hex}" if hex.length.odd?
            bytes = [ hex ].pack("H*")

            if bytes.bytesize > ES512_COORDINATE_BYTES
              bytes = bytes[-ES512_COORDINATE_BYTES, ES512_COORDINATE_BYTES]
            end

            bytes.rjust(ES512_COORDINATE_BYTES, "\x00")
          end

          def base64url(value)
            Base64.urlsafe_encode64(value, padding: false)
          end
        end
      end
    end
  end
end
