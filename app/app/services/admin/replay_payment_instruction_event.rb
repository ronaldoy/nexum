module Admin
  class ReplayPaymentInstructionEvent
    ACTION_TYPE = "PAYMENT_INSTRUCTION_EVENT_REPLAY_REQUESTED".freeze

    class ValidationError < StandardError
      attr_reader :code

      def initialize(code:, message:)
        @code = code.to_s
        super(message)
      end
    end

    def initialize(tenant:, actor:, request_id:, request_ip:, user_agent:, endpoint_path:)
      @tenant = tenant
      @actor = actor
      @request_id = request_id
      @request_ip = request_ip
      @user_agent = user_agent
      @endpoint_path = endpoint_path
    end

    def call(outbox_event_id:)
      source_event = OutboxEvent.where(tenant_id: tenant.id).find(outbox_event_id)
      ensure_replayable!(source_event)

      replayed_event = OutboxEvent.create!(
        tenant: tenant,
        aggregate_type: source_event.aggregate_type,
        aggregate_id: source_event.aggregate_id,
        event_type: source_event.event_type,
        status: "PENDING",
        idempotency_key: replay_idempotency_key_for(source_event),
        payload: replay_payload_for(source_event)
      )

      create_action_log!(source_event:, replayed_event:)
      replayed_event
    end

    private

    attr_reader :tenant, :actor, :request_id, :request_ip, :user_agent, :endpoint_path

    def ensure_replayable!(source_event)
      unless Outbox::PaymentInstructionEventTracker::EVENT_TYPES.key?(source_event.event_type)
        raise ValidationError.new(
          code: "payment_instruction_event_replay_unsupported",
          message: "Only payment instruction outbox events can be replayed from this screen."
        )
      end

      unless source_event.latest_dispatch_attempt&.status == "DEAD_LETTER"
        raise ValidationError.new(
          code: "payment_instruction_event_not_dead_letter",
          message: "Only dead-letter payment instruction events can be replayed."
        )
      end
    end

    def replay_payload_for(source_event)
      normalize_metadata(source_event.payload).merge(
        "replayed_from_outbox_event_id" => source_event.id,
        "replayed_at" => Time.current.utc.iso8601(6)
      )
    end

    def replay_idempotency_key_for(source_event)
      "#{source_event.idempotency_key}:replay:#{SecureRandom.hex(6)}"
    end

    def create_action_log!(source_event:, replayed_event:)
      ActionIpLog.create!(
        tenant_id: tenant.id,
        actor_party_id: actor&.party_id,
        action_type: ACTION_TYPE,
        ip_address: request_ip.presence || "0.0.0.0",
        user_agent: user_agent,
        request_id: request_id,
        endpoint_path: endpoint_path,
        http_method: "POST",
        channel: "ADMIN",
        target_type: "OutboxEvent",
        target_id: replayed_event.id,
        success: true,
        occurred_at: Time.current,
        metadata: {
          "event_type" => source_event.event_type,
          "replayed_from_outbox_event_id" => source_event.id,
          "original_idempotency_key" => source_event.idempotency_key
        }
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => error
      Rails.logger.error(
        "payment_instruction_event_replay_action_log_write_error " \
        "source_outbox_event_id=#{source_event.id} replayed_outbox_event_id=#{replayed_event.id} " \
        "error_class=#{error.class.name} error_message=#{error.message}"
      )
    end

    def normalize_metadata(raw_metadata)
      case raw_metadata
      when ActionController::Parameters
        normalize_metadata(raw_metadata.to_unsafe_h)
      when Hash
        raw_metadata.each_with_object({}) do |(key, value), output|
          output[key.to_s] = normalize_metadata(value)
        end
      when Array
        raw_metadata.map { |entry| normalize_metadata(entry) }
      else
        raw_metadata
      end
    end
  end
end
