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
      now = @clock.call

      ActiveRecord::Base.transaction do
        outbox_event = OutboxEvent.lock.find(outbox_event_id)
        latest_attempt = latest_attempt_for(outbox_event)

        if terminal_state?(latest_attempt)
          return Result.new(
            status: latest_attempt.status,
            attempt_number: latest_attempt.attempt_number,
            skipped: true,
            reason: "already_terminal"
          )
        end

        if retry_not_due_yet?(latest_attempt, now)
          return Result.new(
            status: latest_attempt.status,
            attempt_number: latest_attempt.attempt_number,
            next_attempt_at: latest_attempt.next_attempt_at,
            skipped: true,
            reason: "retry_not_due"
          )
        end

        attempt_number = latest_attempt&.attempt_number.to_i + 1

        begin
          deliver!(outbox_event)
          create_attempt!(
            outbox_event: outbox_event,
            attempt_number: attempt_number,
            status: "SENT",
            occurred_at: now
          )
          create_action_log!(
            outbox_event: outbox_event,
            action_type: DISPATCHED_ACTION,
            success: true,
            metadata: {
              "attempt_number" => attempt_number
            }
          )
          return Result.new(status: "SENT", attempt_number: attempt_number, skipped: false)
        rescue DeliveryError => error
          return handle_delivery_error!(
            outbox_event: outbox_event,
            attempt_number: attempt_number,
            occurred_at: now,
            error: error
          )
        end
      end
    end

    private

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

    def handle_delivery_error!(outbox_event:, attempt_number:, occurred_at:, error:)
      if attempt_number >= @max_attempts
        create_attempt!(
          outbox_event: outbox_event,
          attempt_number: attempt_number,
          status: "DEAD_LETTER",
          occurred_at: occurred_at,
          error_code: error.code,
          error_message: error.message
        )
        create_action_log!(
          outbox_event: outbox_event,
          action_type: DEAD_LETTERED_ACTION,
          success: false,
          metadata: {
            "attempt_number" => attempt_number,
            "error_code" => error.code,
            "error_message" => error.message
          }
        )
        return Result.new(status: "DEAD_LETTER", attempt_number: attempt_number, skipped: false)
      end

      backoff_seconds = @backoff_strategy.call(attempt_number).to_i
      next_attempt_at = occurred_at + backoff_seconds.seconds
      create_attempt!(
        outbox_event: outbox_event,
        attempt_number: attempt_number,
        status: "RETRY_SCHEDULED",
        occurred_at: occurred_at,
        next_attempt_at: next_attempt_at,
        error_code: error.code,
        error_message: error.message,
        metadata: { "backoff_seconds" => backoff_seconds }
      )
      create_action_log!(
        outbox_event: outbox_event,
        action_type: RETRY_SCHEDULED_ACTION,
        success: false,
        metadata: {
          "attempt_number" => attempt_number,
          "error_code" => error.code,
          "error_message" => error.message,
          "next_attempt_at" => next_attempt_at.utc.iso8601(6)
        }
      )
      Result.new(
        status: "RETRY_SCHEDULED",
        attempt_number: attempt_number,
        next_attempt_at: next_attempt_at,
        skipped: false
      )
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

      configured = Integer(
        Rails.app.creds.option(
          :outbox,
          :max_dispatch_attempts,
          default: ENV["OUTBOX_MAX_DISPATCH_ATTEMPTS"]
        ),
        exception: false
      )
      return configured if configured.present? && configured.positive?

      DEFAULT_MAX_ATTEMPTS
    end

    def default_backoff_seconds(attempt_number)
      seconds = RETRY_BASE_SECONDS * (2**[ attempt_number - 1, 0 ].max)
      [ seconds, RETRY_MAX_SECONDS ].min
    end
  end
end
