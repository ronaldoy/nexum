module Security
  class PaymentInstructionsOutboxMonitor
    CACHE_NAMESPACE = "security:payment_instruction_outbox".freeze
    ALERT_EVENT_NAME = "alert.security".freeze
    DEFAULT_DEAD_LETTER_THRESHOLD = 1
    DEFAULT_STALE_THRESHOLD = 1
    DEFAULT_ALERT_WINDOW_SECONDS = 300

    class << self
      def readiness_status(now: Time.current, cache: nil, report: true)
        return "ok" unless enabled?

        cache = resolve_cache(cache)
        snapshot = tracker.snapshot(now:)
        emit_alert_if_threshold_crossed!(snapshot:, now:, cache:) if report

        unhealthy?(snapshot) ? "error" : "ok"
      rescue StandardError => error
        Rails.logger.error("payment_instruction_outbox_monitor_error error_class=#{error.class} message=#{error.message}")
        "error"
      end

      def snapshot(now: Time.current)
        tracker.snapshot(now:)
      end

      def enabled?
        boolean_env("SECURITY_PAYMENT_INSTRUCTIONS_MONITOR_ENABLED", default: Rails.env.production?)
      end

      def reset_for_test!
        return unless Rails.env.test?

        @fallback_cache&.clear
      end

      private

      def tracker
        Outbox::PaymentInstructionEventTracker.new(stale_after_seconds: stale_after_seconds)
      end

      def unhealthy?(snapshot)
        snapshot.fetch(:stale_count) >= stale_threshold || snapshot.fetch(:dead_letter_count) >= dead_letter_threshold
      end

      def emit_alert_if_threshold_crossed!(snapshot:, now:, cache:)
        return unless unhealthy?(snapshot)
        return if alert_emitted_for_window?(now:, cache:)

        mark_alert_emitted_for_window!(now:, cache:)

        payload = {
          alert_type: "payment_instruction_outbox_backlog",
          severity: snapshot.fetch(:dead_letter_count).positive? ? "error" : "warning",
          stale_count: snapshot.fetch(:stale_count),
          dead_letter_count: snapshot.fetch(:dead_letter_count),
          retry_scheduled_count: snapshot.fetch(:retry_scheduled_count),
          stale_threshold: stale_threshold,
          dead_letter_threshold: dead_letter_threshold,
          stale_after_seconds: stale_after_seconds,
          service: name
        }

        ActiveSupport::Notifications.instrument(ALERT_EVENT_NAME, payload)
        Rails.logger.error(
          "security_alert type=#{payload[:alert_type]} severity=#{payload[:severity]} " \
          "stale_count=#{payload[:stale_count]} dead_letter_count=#{payload[:dead_letter_count]} " \
          "retry_scheduled_count=#{payload[:retry_scheduled_count]} stale_threshold=#{payload[:stale_threshold]} " \
          "dead_letter_threshold=#{payload[:dead_letter_threshold]}"
        )
      end

      def stale_after_seconds
        parsed = ENV.fetch(
          "SECURITY_PAYMENT_INSTRUCTIONS_STALE_AFTER_SECONDS",
          Outbox::PaymentInstructionEventTracker::DEFAULT_STALE_AFTER_SECONDS.to_s
        ).to_i
        parsed.positive? ? parsed : Outbox::PaymentInstructionEventTracker::DEFAULT_STALE_AFTER_SECONDS
      end

      def stale_threshold
        parsed = ENV.fetch("SECURITY_PAYMENT_INSTRUCTIONS_STALE_THRESHOLD", DEFAULT_STALE_THRESHOLD.to_s).to_i
        parsed.positive? ? parsed : DEFAULT_STALE_THRESHOLD
      end

      def dead_letter_threshold
        parsed = ENV.fetch("SECURITY_PAYMENT_INSTRUCTIONS_DEAD_LETTER_THRESHOLD", DEFAULT_DEAD_LETTER_THRESHOLD.to_s).to_i
        parsed.positive? ? parsed : DEFAULT_DEAD_LETTER_THRESHOLD
      end

      def resolve_cache(cache)
        cache || default_cache
      end

      def default_cache
        return Rails.cache unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

        @fallback_cache ||= ActiveSupport::Cache::MemoryStore.new
      end

      def alert_emitted_for_window?(now:, cache:)
        cache.read(alert_window_cache_key(now:)).present?
      end

      def mark_alert_emitted_for_window!(now:, cache:)
        cache.write(alert_window_cache_key(now:), true, expires_in: cache_ttl)
      end

      def alert_window_cache_key(now:)
        "#{CACHE_NAMESPACE}:alerts:window:#{now.to_i / alert_window_seconds}"
      end

      def cache_ttl
        [ alert_window_seconds, DEFAULT_ALERT_WINDOW_SECONDS ].max.seconds
      end

      def alert_window_seconds
        DEFAULT_ALERT_WINDOW_SECONDS
      end

      def boolean_env(key, default:)
        ActiveModel::Type::Boolean.new.cast(ENV.fetch(key, default.to_s))
      end
    end
  end
end
