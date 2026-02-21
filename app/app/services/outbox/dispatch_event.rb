module Outbox
  class DispatchEvent
    DEFAULT_MAX_ATTEMPTS = 5
    RETRY_BASE_SECONDS = 30
    RETRY_MAX_SECONDS = 30.minutes.to_i

    DISPATCHED_ACTION = "OUTBOX_EVENT_DISPATCHED".freeze
    RETRY_SCHEDULED_ACTION = "OUTBOX_EVENT_RETRY_SCHEDULED".freeze
    DEAD_LETTERED_ACTION = "OUTBOX_EVENT_DEAD_LETTERED".freeze

    Result = Struct.new(
      :status,
      :attempt_number,
      :next_attempt_at,
      :skipped,
      :reason,
      keyword_init: true
    ) do
      def retry_scheduled?
        status == "RETRY_SCHEDULED"
      end

      def skipped?
        skipped == true
      end
    end
    DispatchContext = Struct.new(:outbox_event, :latest_attempt, :attempt_number, :occurred_at, keyword_init: true)

    DeliveryError = Class.new(StandardError) do
      attr_reader :code

      def initialize(code:, message:)
        @code = code
        super(message)
      end
    end

    def initialize(max_attempts: nil, clock: -> { Time.current }, backoff_strategy: nil)
      @max_attempts = normalize_max_attempts(max_attempts)
      @clock = clock
      @backoff_strategy = backoff_strategy || method(:default_backoff_seconds)
    end

    def call(outbox_event_id:)
      ActiveRecord::Base.transaction do
        context = build_dispatch_context(outbox_event_id: outbox_event_id, occurred_at: @clock.call)
        skip_result = skip_result_for(context)
        return skip_result if skip_result

        process_dispatch_attempt(context: context)
      end
    end

    private

    def build_dispatch_context(outbox_event_id:, occurred_at:)
      outbox_event = OutboxEvent.lock.find(outbox_event_id)
      latest_attempt = latest_attempt_for(outbox_event)
      attempt_number = next_attempt_number(latest_attempt)

      DispatchContext.new(
        outbox_event: outbox_event,
        latest_attempt: latest_attempt,
        attempt_number: attempt_number,
        occurred_at: occurred_at
      )
    end

    def skip_result_for(context)
      return terminal_skip_result(context.latest_attempt) if terminal_state?(context.latest_attempt)
      return retry_not_due_result(context.latest_attempt) if retry_not_due_yet?(context.latest_attempt, context.occurred_at)

      nil
    end

    def latest_attempt_for(outbox_event)
      OutboxDispatchAttempt
        .where(tenant_id: outbox_event.tenant_id, outbox_event_id: outbox_event.id)
        .order(attempt_number: :desc)
        .first
    end

    def terminal_state?(latest_attempt)
      latest_attempt&.status.in?(%w[SENT DEAD_LETTER])
    end

    def retry_not_due_yet?(latest_attempt, now)
      return false unless latest_attempt&.status == "RETRY_SCHEDULED"
      return false if latest_attempt.next_attempt_at.blank?

      latest_attempt.next_attempt_at > now
    end

    def terminal_skip_result(latest_attempt)
      Result.new(
        status: latest_attempt.status,
        attempt_number: latest_attempt.attempt_number,
        skipped: true,
        reason: "already_terminal"
      )
    end

    def retry_not_due_result(latest_attempt)
      Result.new(
        status: latest_attempt.status,
        attempt_number: latest_attempt.attempt_number,
        next_attempt_at: latest_attempt.next_attempt_at,
        skipped: true,
        reason: "retry_not_due"
      )
    end

    def next_attempt_number(latest_attempt)
      latest_attempt&.attempt_number.to_i + 1
    end

    def process_dispatch_attempt(context:)
      deliver!(context.outbox_event)
      record_dispatch_success(context: context)
    rescue DeliveryError => error
      handle_delivery_error!(context: context, error: error)
    end

    def record_dispatch_success(context:)
      create_attempt!(
        outbox_event: context.outbox_event,
        attempt_number: context.attempt_number,
        status: "SENT",
        occurred_at: context.occurred_at
      )
      create_dispatch_action_log!(
        outbox_event: context.outbox_event,
        action_type: DISPATCHED_ACTION,
        attempt_number: context.attempt_number
      )
      build_result(status: "SENT", attempt_number: context.attempt_number)
    end

    def deliver!(outbox_event)
      simulate_failure = ActiveModel::Type::Boolean.new.cast(
        outbox_event.payload&.dig("simulate_dispatch_failure")
      )
      if simulate_failure
        raise DeliveryError.new(
          code: "simulated_dispatch_failure",
          message: "Simulated dispatch failure."
        )
      end

      Outbox::EventRouter.new.call(outbox_event: outbox_event)
    rescue Outbox::EventRouter::DeliveryError => error
      raise DeliveryError.new(code: error.code, message: error.message)
    end

    def handle_delivery_error!(context:, error:)
      return record_dead_letter_attempt(context:, error:) if context.attempt_number >= @max_attempts

      record_retry_scheduled_attempt(context:, error:)
    end

    def record_dead_letter_attempt(context:, error:)
      record_failed_attempt!(
        context: context,
        status: "DEAD_LETTER",
        action_type: DEAD_LETTERED_ACTION,
        error: error
      )
    end

    def record_retry_scheduled_attempt(context:, error:)
      backoff_seconds = backoff_seconds_for(context.attempt_number)
      next_attempt_at = context.occurred_at + backoff_seconds.seconds
      record_failed_attempt!(
        context: context,
        status: "RETRY_SCHEDULED",
        action_type: RETRY_SCHEDULED_ACTION,
        error: error,
        next_attempt_at: next_attempt_at,
        attempt_metadata: { "backoff_seconds" => backoff_seconds }
      )
    end

    def record_failed_attempt!(
      context:,
      status:,
      action_type:,
      error:,
      next_attempt_at: nil,
      attempt_metadata: {}
    )
      create_attempt!(
        outbox_event: context.outbox_event,
        attempt_number: context.attempt_number,
        status: status,
        occurred_at: context.occurred_at,
        next_attempt_at: next_attempt_at,
        error_code: error.code,
        error_message: error.message,
        metadata: attempt_metadata
      )
      create_dispatch_action_log!(
        outbox_event: context.outbox_event,
        action_type: action_type,
        attempt_number: context.attempt_number,
        error: error,
        next_attempt_at: next_attempt_at
      )
      build_result(
        status: status,
        attempt_number: context.attempt_number,
        next_attempt_at: next_attempt_at
      )
    end

    def build_result(status:, attempt_number:, next_attempt_at: nil)
      Result.new(
        status: status,
        attempt_number: attempt_number,
        next_attempt_at: next_attempt_at,
        skipped: false
      )
    end

    def backoff_seconds_for(attempt_number)
      @backoff_strategy.call(attempt_number).to_i
    end

    def create_dispatch_action_log!(outbox_event:, action_type:, attempt_number:, error: nil, next_attempt_at: nil)
      create_action_log!(
        outbox_event: outbox_event,
        action_type: action_type,
        success: action_type == DISPATCHED_ACTION,
        metadata: dispatch_action_metadata(
          attempt_number: attempt_number,
          error: error,
          next_attempt_at: next_attempt_at
        )
      )
    end

    def dispatch_action_metadata(attempt_number:, error:, next_attempt_at:)
      metadata = { "attempt_number" => attempt_number }
      metadata["error_code"] = error.code if error
      metadata["error_message"] = error.message if error
      metadata["next_attempt_at"] = next_attempt_at.utc.iso8601(6) if next_attempt_at
      metadata
    end

    def create_attempt!(
      outbox_event:,
      attempt_number:,
      status:,
      occurred_at:,
      next_attempt_at: nil,
      error_code: nil,
      error_message: nil,
      metadata: {}
    )
      OutboxDispatchAttempt.create!(
        tenant_id: outbox_event.tenant_id,
        outbox_event_id: outbox_event.id,
        attempt_number: attempt_number,
        status: status,
        occurred_at: occurred_at,
        next_attempt_at: next_attempt_at,
        error_code: error_code,
        error_message: error_message.to_s.truncate(500),
        metadata: metadata
      )
    end

    def create_action_log!(outbox_event:, action_type:, success:, metadata:)
      ActionIpLog.create!(
        tenant_id: outbox_event.tenant_id,
        action_type: action_type,
        ip_address: "0.0.0.0",
        request_id: nil,
        endpoint_path: "/workers/outbox/dispatch_event",
        http_method: "JOB",
        channel: "WORKER",
        target_type: "OutboxEvent",
        target_id: outbox_event.id,
        success: success,
        occurred_at: @clock.call,
        metadata: metadata
      )
    end

    def normalize_max_attempts(value)
      parsed = Integer(value, exception: false)
      return parsed if parsed.present? && parsed.positive?

      configured = configured_max_attempts
      return configured if configured.present? && configured.positive?

      DEFAULT_MAX_ATTEMPTS
    end

    def configured_max_attempts
      Integer(
        Rails.app.creds.option(
          :outbox,
          :max_dispatch_attempts,
          default: ENV["OUTBOX_MAX_DISPATCH_ATTEMPTS"]
        ),
        exception: false
      )
    end

    def default_backoff_seconds(attempt_number)
      seconds = RETRY_BASE_SECONDS * (2**[ attempt_number - 1, 0 ].max)
      [ seconds, RETRY_MAX_SECONDS ].min
    end
  end
end
