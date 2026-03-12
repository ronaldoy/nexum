module Outbox
  class PaymentInstructionEventTracker
    EVENT_TYPES = {
      "RECEIVABLE_ESCROW_PAYMENT_INSTRUCTIONS_REFRESH_REQUESTED" => "Refresh PIX inbound",
      "RECEIVABLE_HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_REQUESTED" => "Sync hospital API"
    }.freeze
    DEFAULT_STALE_AFTER_SECONDS = 10.minutes.to_i

    def initialize(stale_after_seconds: nil)
      @stale_after_seconds = normalize_stale_after_seconds(stale_after_seconds)
    end

    def snapshot(tenant_id: nil, now: Time.current)
      scope = tracked_scope(tenant_id:)
      stale_scope = stale_events(scope:, now:)
      dead_letter_scope = dead_letter_events(scope:)

      oldest_stale_created_at = stale_scope.reorder("outbox_events.created_at ASC").limit(1).pick("outbox_events.created_at")

      {
        pending_count: pending_events(scope:, now:).count,
        retry_scheduled_count: retry_scheduled_events(scope:).count,
        stale_count: stale_scope.count,
        dead_letter_count: dead_letter_scope.count,
        oldest_stale_created_at: oldest_stale_created_at,
        oldest_stale_age_seconds: oldest_stale_created_at.present? ? [ now - oldest_stale_created_at, 0 ].max.to_i : nil
      }
    end

    def problematic_rows(tenant_id:, now: Time.current, limit: 10)
      problematic_scope(tenant_id:, now:)
        .select(<<~SQL.squish)
          outbox_events.*,
          latest_attempt.status AS latest_attempt_status,
          latest_attempt.next_attempt_at AS latest_attempt_next_attempt_at,
          latest_attempt.attempt_number AS latest_attempt_attempt_number,
          latest_attempt.error_code AS latest_attempt_error_code,
          latest_attempt.error_message AS latest_attempt_error_message,
          latest_attempt.occurred_at AS latest_attempt_occurred_at
        SQL
        .order(Arel.sql(problematic_order_sql))
        .limit(limit)
        .map { |event| build_problematic_row(event:, now:) }
    end

    def replayable_event?(outbox_event)
      return false if outbox_event.blank?

      EVENT_TYPES.key?(outbox_event.event_type) && outbox_event.latest_dispatch_attempt&.status == "DEAD_LETTER"
    end

    private

    attr_reader :stale_after_seconds

    def tracked_scope(tenant_id:)
      scope = OutboxEvent
        .where(event_type: EVENT_TYPES.keys)
        .joins(latest_attempt_join_sql)
      tenant_id.present? ? scope.where(tenant_id: tenant_id) : scope
    end

    def pending_events(scope:, now:)
      scope.where("latest_attempt.status IS NULL AND outbox_events.created_at > ?", stale_cutoff(now))
    end

    def retry_scheduled_events(scope:)
      scope.where("latest_attempt.status = ?", "RETRY_SCHEDULED")
    end

    def dead_letter_events(scope:)
      scope.where("latest_attempt.status = ?", "DEAD_LETTER")
    end

    def stale_events(scope:, now:)
      scope.where(
        <<~SQL.squish,
          (
            latest_attempt.status IS NULL
            AND outbox_events.created_at <= :stale_cutoff
          )
          OR (
            latest_attempt.status = 'RETRY_SCHEDULED'
            AND COALESCE(latest_attempt.next_attempt_at, outbox_events.created_at) <= :now
          )
        SQL
        stale_cutoff: stale_cutoff(now),
        now: now
      )
    end

    def problematic_scope(tenant_id:, now:)
      scope = tracked_scope(tenant_id:)
      stale_scope = stale_events(scope:, now:)
      dead_letter_scope = dead_letter_events(scope:)

      scope.where(
        "outbox_events.id IN (#{stale_scope.select(:id).to_sql}) OR outbox_events.id IN (#{dead_letter_scope.select(:id).to_sql})"
      )
    end

    def latest_attempt_join_sql
      <<~SQL.squish
        LEFT JOIN LATERAL (
          SELECT
            attempts.status,
            attempts.next_attempt_at,
            attempts.attempt_number,
            attempts.error_code,
            attempts.error_message,
            attempts.occurred_at
          FROM outbox_dispatch_attempts attempts
          WHERE attempts.tenant_id = outbox_events.tenant_id
            AND attempts.outbox_event_id = outbox_events.id
          ORDER BY attempts.attempt_number DESC
          LIMIT 1
        ) latest_attempt ON TRUE
      SQL
    end

    def problematic_order_sql
      <<~SQL.squish
        CASE
          WHEN latest_attempt.status = 'DEAD_LETTER' THEN 0
          WHEN latest_attempt.status = 'RETRY_SCHEDULED' THEN 1
          ELSE 2
        END,
        outbox_events.created_at ASC
      SQL
    end

    def build_problematic_row(event:, now:)
      latest_status = event.attributes["latest_attempt_status"].presence || "PENDING"
      created_at = event.created_at
      {
        event: event,
        event_type_label: EVENT_TYPES.fetch(event.event_type),
        latest_status: latest_status,
        stale: stale_row?(latest_status:, event:, now:),
        replayable: latest_status == "DEAD_LETTER",
        age_seconds: [ now - created_at, 0 ].max.to_i,
        age_label: ActionController::Base.helpers.distance_of_time_in_words(created_at, now),
        next_attempt_at: event.attributes["latest_attempt_next_attempt_at"],
        attempt_number: event.attributes["latest_attempt_attempt_number"].to_i.nonzero?,
        error_code: event.attributes["latest_attempt_error_code"].presence,
        error_message: event.attributes["latest_attempt_error_message"].presence,
        latest_attempt_occurred_at: event.attributes["latest_attempt_occurred_at"]
      }
    end

    def stale_row?(latest_status:, event:, now:)
      return true if latest_status == "PENDING" && event.created_at <= stale_cutoff(now)
      return false unless latest_status == "RETRY_SCHEDULED"

      next_attempt_at = event.attributes["latest_attempt_next_attempt_at"]
      next_attempt_at.blank? || next_attempt_at <= now
    end

    def stale_cutoff(now)
      now - stale_after_seconds.seconds
    end

    def normalize_stale_after_seconds(value)
      parsed = value.to_i
      parsed.positive? ? parsed : DEFAULT_STALE_AFTER_SECONDS
    end
  end
end
