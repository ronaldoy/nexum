require "test_helper"
require "integrations/escrow/error"

module Integrations
  module Escrow
    module Providers
      class QiTechClientTest < ActiveSupport::TestCase
        SignerDouble = Struct.new(:token) do
          def sign(method:, uri:, body:)
            token || "signed-jwt"
          end
        end

        test "rejects insecure http base url" do
          error = assert_raises(Integrations::Escrow::ConfigurationError) do
            QiTech::Client.new(
              base_url: "http://api.qitech.example.test",
              api_client_key: "client-key",
              signer: SignerDouble.new
            )
          end

          assert_equal "qitech_base_url_invalid", error.code
          assert_equal "must use HTTPS", error.details[:reason]
        end

        test "rejects base url with embedded credentials" do
          error = assert_raises(Integrations::Escrow::ConfigurationError) do
            QiTech::Client.new(
              base_url: "https://user:pass@api.qitech.example.test",
              api_client_key: "client-key",
              signer: SignerDouble.new
            )
          end

          assert_equal "qitech_base_url_invalid", error.code
          assert_equal "must not include userinfo", error.details[:reason]
        end
      end
    end
  end
end
