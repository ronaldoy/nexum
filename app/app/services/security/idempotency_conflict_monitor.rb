module Security
  class IdempotencyConflictMonitor
    CACHE_NAMESPACE = "security:idempotency_conflicts".freeze
    ALERT_EVENT_NAME = "security.alert".freeze
    DEFAULT_THRESHOLD = 20
    DEFAULT_WINDOW_SECONDS = 300

    class << self
      def record_conflict!(payload:, occurred_at: Time.current, cache: nil)
        return nil unless enabled?
        cache = resolve_cache(cache)

        bucket_key = bucket_cache_key(at: occurred_at)
        incremented = cache.increment(bucket_key, 1, initial: 0, expires_in: cache_ttl)
        if incremented.nil?
          next_value = cache.read(bucket_key).to_i + 1
          cache.write(bucket_key, next_value, expires_in: cache_ttl)
        end

        conflict_count = rolling_conflict_count(now: occurred_at, cache:)

        emit_alert_if_threshold_crossed!(
          conflict_count: conflict_count,
          occurred_at: occurred_at,
          payload: payload,
          cache:
        )

        conflict_count
      rescue StandardError => error
        Rails.logger.error("idempotency_conflict_monitor_error error_class=#{error.class} message=#{error.message}")
        nil
      end

      def readiness_status(now: Time.current, cache: nil)
        return "ok" unless enabled?
        cache = resolve_cache(cache)

        rolling_conflict_count(now:, cache:) > threshold ? "error" : "ok"
      rescue StandardError => error
        Rails.logger.error("idempotency_conflict_readiness_error error_class=#{error.class} message=#{error.message}")
        "error"
      end

      def rolling_conflict_count(now: Time.current, cache: nil)
        cache = resolve_cache(cache)
        current_bucket_number = bucket_number(now)
        window_bucket_count.times.sum do |offset|
          cache.read(bucket_cache_key(number: current_bucket_number - offset)).to_i
        end
      end

      def enabled?
        boolean_env("SECURITY_IDEMPOTENCY_MONITOR_ENABLED", default: Rails.env.production?)
      end

      def threshold
        parsed = ENV.fetch("SECURITY_IDEMPOTENCY_CONFLICT_THRESHOLD", DEFAULT_THRESHOLD.to_s).to_i
        parsed.positive? ? parsed : DEFAULT_THRESHOLD
      end

      def window_seconds
        parsed = ENV.fetch("SECURITY_IDEMPOTENCY_CONFLICT_WINDOW_SECONDS", DEFAULT_WINDOW_SECONDS.to_s).to_i
        parsed.positive? ? parsed : DEFAULT_WINDOW_SECONDS
      end

      def reset_for_test!
        return unless Rails.env.test?

        @fallback_cache&.clear
      end

      private

      def resolve_cache(cache)
        cache || default_cache
      end

      def default_cache
        return Rails.cache unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

        @fallback_cache ||= ActiveSupport::Cache::MemoryStore.new
      end

      def emit_alert_if_threshold_crossed!(conflict_count:, occurred_at:, payload:, cache:)
        return if conflict_count <= threshold
        return if alert_emitted_for_window?(occurred_at:, cache:)

        mark_alert_emitted_for_window!(occurred_at:, cache:)

        alert_payload = {
          alert_type: "idempotency_conflict_spike",
          severity: "warning",
          conflicts_in_window: conflict_count,
          threshold: threshold,
          window_seconds: window_seconds,
          service: payload[:service],
          tenant_id: payload[:tenant_id]
        }

        ActiveSupport::Notifications.instrument(ALERT_EVENT_NAME, alert_payload)
        Rails.logger.error(
          "security_alert type=#{alert_payload[:alert_type]} " \
            "severity=#{alert_payload[:severity]} " \
            "conflicts_in_window=#{alert_payload[:conflicts_in_window]} " \
            "threshold=#{alert_payload[:threshold]} " \
            "window_seconds=#{alert_payload[:window_seconds]} " \
            "service=#{alert_payload[:service]} " \
            "tenant_id=#{alert_payload[:tenant_id]}"
        )
      end

      def alert_window_cache_key(at:)
        "#{CACHE_NAMESPACE}:alerts:window:#{window_marker(at)}"
      end

      def alert_emitted_for_window?(occurred_at:, cache:)
        cache.read(alert_window_cache_key(at: occurred_at)).present?
      end

      def mark_alert_emitted_for_window!(occurred_at:, cache:)
        cache.write(alert_window_cache_key(at: occurred_at), true, expires_in: cache_ttl)
      end

      def window_marker(time)
        bucket_number(time) / window_bucket_count
      end

      def cache_ttl
        [ window_seconds, 300 ].max.seconds
      end

      def window_bucket_count
        (window_seconds / 60.0).ceil
      end

      def bucket_number(time)
        time.to_i / 60
      end

      def bucket_cache_key(at: nil, number: nil)
        bucket_number_value = number || bucket_number(at || Time.current)
        "#{CACHE_NAMESPACE}:buckets:#{bucket_number_value}"
      end

      def boolean_env(key, default:)
        ActiveModel::Type::Boolean.new.cast(ENV.fetch(key, default.to_s))
      end
    end
  end
end
