require "test_helper"

module Idempotency
  class OutboxReplayValidationTest < ActiveSupport::TestCase
    OutboxDouble = Struct.new(:event_type, :aggregate_type, :payload, keyword_init: true)

    class DummyService
      include Idempotency::OutboxReplayValidation

      OUTBOX_EVENT_TYPE = "TEST_EVENT".freeze
      TARGET_TYPE = "TestAggregate".freeze
      PAYLOAD_HASH_KEY = "payload_hash".freeze

      class IdempotencyConflict < StandardError
        attr_reader :code

        def initialize(code:, message:)
          super(message)
          @code = code
        end
      end
    end

    class CustomPayloadConflictService < DummyService
      private

      def idempotency_payload_conflict_message
        "custom payload conflict message"
      end
    end

    class LegacyPayloadHashService < DummyService
      private

      def allow_blank_replay_payload_hash?
        true
      end
    end

    class MissingEventTypeService
      include Idempotency::OutboxReplayValidation

      TARGET_TYPE = "TestAggregate".freeze
      PAYLOAD_HASH_KEY = "payload_hash".freeze

      class IdempotencyConflict < StandardError
        attr_reader :code

        def initialize(code:, message:)
          super(message)
          @code = code
        end
      end
    end

    setup do
      @service = DummyService.new
    end

    test "accepts replay when outbox operation matches expected operation" do
      outbox = OutboxDouble.new(
        event_type: "TEST_EVENT",
        aggregate_type: "TestAggregate",
        payload: {}
      )

      result = @service.send(:ensure_replay_outbox_operation!, outbox)

      assert_nil result
    end

    test "rejects replay when outbox operation differs from expected operation" do
      outbox = OutboxDouble.new(
        event_type: "OTHER_EVENT",
        aggregate_type: "TestAggregate",
        payload: {}
      )

      error = assert_raises(DummyService::IdempotencyConflict) do
        @service.send(:ensure_replay_outbox_operation!, outbox)
      end

      assert_equal "idempotency_key_reused_with_different_operation", error.code
      assert_equal "Idempotency-Key was already used with a different operation.", error.message
    end

    test "accepts replay when payload hash matches" do
      outbox = OutboxDouble.new(
        event_type: "TEST_EVENT",
        aggregate_type: "TestAggregate",
        payload: { "payload_hash" => "abc123" }
      )

      result = @service.send(:ensure_replay_payload_hash!, existing_outbox: outbox, payload_hash: "abc123")

      assert_nil result
    end

    test "rejects replay when outbox payload hash is missing" do
      outbox = OutboxDouble.new(
        event_type: "TEST_EVENT",
        aggregate_type: "TestAggregate",
        payload: {}
      )

      error = assert_raises(DummyService::IdempotencyConflict) do
        @service.send(:ensure_replay_payload_hash!, existing_outbox: outbox, payload_hash: "abc123")
      end

      assert_equal "idempotency_key_reused_without_payload_hash", error.code
      assert_equal "Idempotency-Key replay is blocked because stored payload hash evidence is missing.", error.message
    end

    test "rejects replay when payload hash differs" do
      outbox = OutboxDouble.new(
        event_type: "TEST_EVENT",
        aggregate_type: "TestAggregate",
        payload: { "payload_hash" => "stored-hash" }
      )

      error = assert_raises(DummyService::IdempotencyConflict) do
        @service.send(:ensure_replay_payload_hash!, existing_outbox: outbox, payload_hash: "incoming-hash")
      end

      assert_equal "idempotency_key_reused_with_different_payload", error.code
      assert_equal "Idempotency-Key was already used with a different payload.", error.message
    end

    test "supports custom payload conflict message overrides" do
      outbox = OutboxDouble.new(
        event_type: "TEST_EVENT",
        aggregate_type: "TestAggregate",
        payload: { "payload_hash" => "stored-hash" }
      )
      service = CustomPayloadConflictService.new

      error = assert_raises(DummyService::IdempotencyConflict) do
        service.send(:ensure_replay_payload_hash!, existing_outbox: outbox, payload_hash: "incoming-hash")
      end

      assert_equal "custom payload conflict message", error.message
    end

    test "supports legacy explicit opt-in to allow blank stored payload hash" do
      outbox = OutboxDouble.new(
        event_type: "TEST_EVENT",
        aggregate_type: "TestAggregate",
        payload: {}
      )
      service = LegacyPayloadHashService.new

      result = service.send(:ensure_replay_payload_hash!, existing_outbox: outbox, payload_hash: "incoming-hash")

      assert_nil result
    end

    test "raises not implemented error when required constants are missing" do
      outbox = OutboxDouble.new(
        event_type: "ANY_EVENT",
        aggregate_type: "TestAggregate",
        payload: {}
      )
      service = MissingEventTypeService.new

      error = assert_raises(NotImplementedError) do
        service.send(:ensure_replay_outbox_operation!, outbox)
      end

      assert_includes error.message, "MissingEventTypeService must define OUTBOX_EVENT_TYPE"
    end
  end
end
