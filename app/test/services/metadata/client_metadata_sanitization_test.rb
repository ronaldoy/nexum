require "test_helper"

module Metadata
  class ClientMetadataSanitizationTest < ActiveSupport::TestCase
    class DummyService
      include Metadata::ClientMetadataSanitization

      DEFAULT_CLIENT_METADATA_KEYS = %w[source source_system source_channel].freeze

      class ValidationError < StandardError
        attr_reader :code

        def initialize(code:, message:)
          super(message)
          @code = code
        end
      end

      def initialize(configured_metadata_allowed_keys: nil)
        @configured_metadata_allowed_keys = configured_metadata_allowed_keys
      end

      private

      def metadata_allowed_keys_credential_key
        :dummy_metadata_allowed_keys
      end

      def metadata_allowed_keys_env_var
        "DUMMY_METADATA_ALLOWED_KEYS"
      end

      def configured_metadata_allowed_keys
        return @configured_metadata_allowed_keys unless @configured_metadata_allowed_keys.nil?

        super
      end

      def normalize_metadata(raw_metadata)
        case raw_metadata
        when Hash
          raw_metadata.each_with_object({}) do |(key, value), output|
            output[key.to_s] = value
          end
        else
          raw_metadata
        end
      end

      def raise_validation_error!(code, message)
        raise ValidationError.new(code:, message:)
      end
    end

    class MissingDefaultKeysService
      include Metadata::ClientMetadataSanitization

      class ValidationError < StandardError
        attr_reader :code

        def initialize(code:, message:)
          super(message)
          @code = code
        end
      end

      private

      def metadata_allowed_keys_credential_key
        :dummy_metadata_allowed_keys
      end

      def metadata_allowed_keys_env_var
        "DUMMY_METADATA_ALLOWED_KEYS"
      end

      def configured_metadata_allowed_keys
        nil
      end

      def normalize_metadata(raw_metadata)
        raw_metadata
      end

      def raise_validation_error!(code, message)
        raise ValidationError.new(code:, message:)
      end
    end

    setup do
      @service = DummyService.new
      @env_key = "DUMMY_METADATA_ALLOWED_KEYS"
      @previous_env_value = ENV[@env_key]
      ENV.delete(@env_key)
    end

    teardown do
      if @previous_env_value.nil?
        ENV.delete(@env_key)
      else
        ENV[@env_key] = @previous_env_value
      end
    end

    test "uses default allowed keys when credentials and env are blank" do
      keys = @service.send(:allowed_client_metadata_keys)

      assert_equal DummyService::DEFAULT_CLIENT_METADATA_KEYS, keys
    end

    test "uses env override when credentials are blank" do
      ENV[@env_key] = "source, custom_reference, source_channel"

      keys = @service.send(:allowed_client_metadata_keys)

      assert_equal %w[source custom_reference source_channel], keys
    end

    test "uses credential override when present" do
      configured_keys = [ "source", "integration_reference", " source_channel " ]
      service = DummyService.new(configured_metadata_allowed_keys: configured_keys)

      keys = service.send(:allowed_client_metadata_keys)

      assert_equal %w[source integration_reference source_channel], keys
    end

    test "sanitizes metadata using resolved allowlist" do
      ENV[@env_key] = "source,source_channel"
      raw_metadata = {
        source: "portal",
        source_channel: "api",
        ignored_key: "drop-me"
      }

      sanitized = @service.send(:sanitize_client_metadata, raw_metadata)

      assert_equal(
        {
          "source" => "portal",
          "source_channel" => "api"
        },
        sanitized
      )
    end

    test "rejects non-object metadata payload" do
      error = assert_raises(DummyService::ValidationError) do
        @service.send(:sanitize_client_metadata, "invalid-metadata")
      end

      assert_equal "invalid_metadata", error.code
      assert_equal "metadata must be a JSON object.", error.message
    end

    test "raises not implemented error when default allowed keys constant is missing" do
      service = MissingDefaultKeysService.new

      error = assert_raises(NotImplementedError) do
        service.send(:allowed_client_metadata_keys)
      end

      assert_includes error.message, "MissingDefaultKeysService must define DEFAULT_CLIENT_METADATA_KEYS"
    end
  end
end
