require "digest"

module AnticipationRisk
  class Evaluator
    OPEN_STATUSES = %w[REQUESTED PENDING_REVIEW APPROVED FUNDED].freeze
    DAILY_STATUSES = %w[REQUESTED PENDING_REVIEW APPROVED FUNDED SETTLED].freeze
    REQUEST_ACTIVITY_STATUSES = %w[REQUESTED PENDING_REVIEW APPROVED FUNDED SETTLED].freeze
    SPIKE_HISTORY_DAYS = 7
    NEAR_LIMIT_DEFAULT_RATIO = BigDecimal("0.90")
    SCOPE_LABELS = {
      "TENANT_DEFAULT" => "tenant",
      "PHYSICIAN_PARTY" => "physician",
      "CNPJ_PARTY" => "cnpj",
      "HOSPITAL_PARTY" => "hospital"
    }.freeze
    ACTION_SEVERITY = {
      "ALLOW" => 0,
      "REVIEW" => 1,
      "BLOCK" => 2
    }.freeze

    Decision = Struct.new(
      :allowed,
      :action,
      :code,
      :message,
      :rule,
      :metric,
      :scope_type,
      :scope_party_id,
      :details,
      keyword_init: true
    ) do
      def allowed?
        allowed
      end

      def metadata
        {
          decision_action: action,
          decision_code: code,
          decision_metric: metric,
          scope_type: scope_type,
          scope_party_id: scope_party_id,
          rule_id: rule&.id,
          details: details
        }.compact
      end
    end

    Usage = Struct.new(:daily_requested_amount, :outstanding_exposure_amount, :open_requests_count, keyword_init: true)

    def initialize(tenant_id:)
      @tenant_id = tenant_id
      @usage_cache = {}
      @cnpj_party_ids_by_document_number = {}
      @cnpj_party_ids_by_scope_party_id = {}
      @velocity_counts_cache = {}
      @pair_spike_cache = {}
      @near_limit_attempts_cache = {}
    end

    def evaluate!(receivable:, receivable_allocation:, requester_party:, requested_amount:, net_amount:, stage:)
      now = Time.current
      scope_map = scope_map(receivable:, receivable_allocation:, requester_party:)
      advisory_lock_keys(
        receivable: receivable,
        receivable_allocation: receivable_allocation,
        requester_party: requester_party,
        scope_map: scope_map,
        now: now
      ).each { |lock_key| advisory_lock!(lock_key) }

      rules = applicable_rules(
        receivable: receivable,
        receivable_allocation: receivable_allocation,
        requester_party: requester_party,
        scope_map: scope_map,
        now: now
      )
      return allow_decision if rules.empty?

      violations = rules.flat_map do |rule|
        evaluate_rule(
          rule: rule,
          receivable: receivable,
          requester_party: requester_party,
          requested_amount: requested_amount,
          net_amount: net_amount,
          stage: stage,
          now: now
        )
      end

      return allow_decision if violations.empty?

      select_violation(violations)
    end

    private

    def allow_decision
      Decision.new(
        allowed: true,
        action: "ALLOW",
        code: "risk_check_passed",
        message: "Risk limits allow this anticipation request.",
        details: {}
      )
    end

    def applicable_rules(receivable:, receivable_allocation:, requester_party:, now:, scope_map: nil)
      scope_map ||= scope_map(receivable:, receivable_allocation:, requester_party:)
      rule_scope = AnticipationRiskRule.where(tenant_id: @tenant_id).active
      rule_scope = rule_scope.where("effective_from IS NULL OR effective_from <= ?", now)
      rule_scope = rule_scope.where("effective_until IS NULL OR effective_until >= ?", now)

      scope_conditions = []
      scope_values = {}

      scope_map.each do |scope_type, scope_party_ids|
        type_key = :"#{scope_key(scope_type)}_type"
        party_key = :"#{scope_key(scope_type)}_party_ids"
        normalized_party_ids = Array(scope_party_ids).compact.uniq

        if normalized_party_ids.empty?
          scope_conditions << "(scope_type = :#{type_key} AND scope_party_id IS NULL)"
          scope_values[type_key] = scope_type
          next
        end

        scope_conditions << "(scope_type = :#{type_key} AND scope_party_id IN (:#{party_key}))"
        scope_values[type_key] = scope_type
        scope_values[party_key] = normalized_party_ids
      end

      return [] if scope_conditions.empty?

      rule_scope.where(scope_conditions.join(" OR "), scope_values)
        .order(priority: :asc, created_at: :asc)
        .to_a
    end

    def scope_map(receivable:, receivable_allocation:, requester_party:)
      map = { "TENANT_DEFAULT" => [] }

      physician_party_id = physician_scope_party_id(receivable_allocation:, requester_party:)
      map["PHYSICIAN_PARTY"] = [ physician_party_id ] if physician_party_id.present?

      cnpj_party_ids = cnpj_scope_party_ids(receivable:, receivable_allocation:, requester_party:)
      map["CNPJ_PARTY"] = cnpj_party_ids if cnpj_party_ids.any?

      hospital_party_id = hospital_scope_party_id(receivable: receivable)
      map["HOSPITAL_PARTY"] = [ hospital_party_id ] if hospital_party_id.present?

      map
    end

    def physician_scope_party_id(receivable_allocation:, requester_party:)
      allocation_party_id = receivable_allocation&.physician_party_id
      return allocation_party_id if allocation_party_id.present?
      return requester_party.id if requester_party.kind == "PHYSICIAN_PF"

      nil
    end

    def cnpj_scope_party_ids(receivable:, receivable_allocation:, requester_party:)
      document_numbers = cnpj_scope_document_numbers(
        receivable: receivable,
        receivable_allocation: receivable_allocation,
        requester_party: requester_party
      )
      return [] if document_numbers.empty?

      document_numbers.flat_map { |document_number| cnpj_party_ids_for_document_number(document_number) }.uniq
    end

    def hospital_scope_party_id(receivable:)
      return receivable.debtor_party_id if receivable.debtor_party&.kind == "HOSPITAL"

      nil
    end

    def evaluate_rule(rule:, receivable:, requester_party:, requested_amount:, net_amount:, stage:, now:)
      usage = usage_for_scope(rule: rule, now: now)
      projected_usage = projected_usage(
        usage: usage,
        requested_amount: requested_amount,
        net_amount: net_amount,
        stage: stage
      )

      violations = []
      if rule.max_single_request_amount.present? && requested_amount > rule.max_single_request_amount.to_d
        violations << build_violation(
          rule: rule,
          metric: "single_request",
          limit_value: rule.max_single_request_amount.to_d,
          observed_value: requested_amount,
          usage: usage,
          projected_usage: projected_usage
        )
      end

      if rule.max_daily_requested_amount.present? && projected_usage.daily_requested_amount > rule.max_daily_requested_amount.to_d
        violations << build_violation(
          rule: rule,
          metric: "daily_requested",
          limit_value: rule.max_daily_requested_amount.to_d,
          observed_value: projected_usage.daily_requested_amount,
          usage: usage,
          projected_usage: projected_usage
        )
      end

      if rule.max_outstanding_exposure_amount.present? && projected_usage.outstanding_exposure_amount > rule.max_outstanding_exposure_amount.to_d
        violations << build_violation(
          rule: rule,
          metric: "outstanding_exposure",
          limit_value: rule.max_outstanding_exposure_amount.to_d,
          observed_value: projected_usage.outstanding_exposure_amount,
          usage: usage,
          projected_usage: projected_usage
        )
      end

      if rule.max_open_requests_count.present? && projected_usage.open_requests_count > rule.max_open_requests_count
        violations << build_violation(
          rule: rule,
          metric: "open_requests",
          limit_value: rule.max_open_requests_count,
          observed_value: projected_usage.open_requests_count,
          usage: usage,
          projected_usage: projected_usage
        )
      end

      velocity_counts = velocity_counts_for_scope(rule: rule, now: now)
      projected_increment = stage.to_s == "confirm" ? 0 : 1
      if rule.max_requests_per_minute.present? && (velocity_counts[:per_minute] + projected_increment) > rule.max_requests_per_minute
        violations << build_violation(
          rule: rule,
          metric: "requests_per_minute",
          limit_value: rule.max_requests_per_minute,
          observed_value: velocity_counts[:per_minute] + projected_increment,
          usage: usage,
          projected_usage: projected_usage,
          extra_details: {
            current_requests_per_minute: velocity_counts[:per_minute]
          }
        )
      end

      if rule.max_requests_per_hour.present? && (velocity_counts[:per_hour] + projected_increment) > rule.max_requests_per_hour
        violations << build_violation(
          rule: rule,
          metric: "requests_per_hour",
          limit_value: rule.max_requests_per_hour,
          observed_value: velocity_counts[:per_hour] + projected_increment,
          usage: usage,
          projected_usage: projected_usage,
          extra_details: {
            current_requests_per_hour: velocity_counts[:per_hour]
          }
        )
      end

      pair_spike = pair_spike_metrics_for(
        receivable: receivable,
        requester_party: requester_party,
        requested_amount: requested_amount,
        stage: stage,
        now: now
      )
      if pair_spike.present? &&
          rule.pair_spike_multiplier.present? &&
          rule.pair_spike_min_daily_amount.present? &&
          pair_spike[:projected_today_amount] >= rule.pair_spike_min_daily_amount.to_d &&
          pair_spike[:baseline_daily_amount].positive? &&
          pair_spike[:projected_today_amount] > pair_spike[:baseline_daily_amount] * rule.pair_spike_multiplier.to_d
        violations << build_violation(
          rule: rule,
          metric: "party_hospital_spike",
          limit_value: pair_spike[:baseline_daily_amount] * rule.pair_spike_multiplier.to_d,
          observed_value: pair_spike[:projected_today_amount],
          usage: usage,
          projected_usage: projected_usage,
          extra_details: {
            requester_party_id: requester_party.id,
            hospital_party_id: pair_spike[:hospital_party_id],
            baseline_daily_amount: decimal_to_string(pair_spike[:baseline_daily_amount]),
            pair_spike_multiplier: rule.pair_spike_multiplier.to_d.to_s("F"),
            pair_spike_min_daily_amount: decimal_to_string(rule.pair_spike_min_daily_amount),
            history_days: SPIKE_HISTORY_DAYS
          }
        )
      end

      if stage.to_s != "confirm" &&
          rule.near_limit_attempts_window_minutes.present? &&
          rule.near_limit_attempts_max_count.present? &&
          rule.max_single_request_amount.present?
        near_limit_ratio = rule.near_limit_ratio.to_d.nonzero? || NEAR_LIMIT_DEFAULT_RATIO
        near_limit_threshold = FinancialRounding.money(rule.max_single_request_amount.to_d * near_limit_ratio)
        if requested_amount >= near_limit_threshold
          recent_attempts = near_limit_attempts_count_for(
            requester_party_id: requester_party.id,
            window_minutes: rule.near_limit_attempts_window_minutes,
            now: now
          )
          projected_attempts = recent_attempts + 1

          if projected_attempts > rule.near_limit_attempts_max_count
            violations << build_violation(
              rule: rule,
              metric: "near_limit_attempts",
              limit_value: rule.near_limit_attempts_max_count,
              observed_value: projected_attempts,
              usage: usage,
              projected_usage: projected_usage,
              extra_details: {
                near_limit_threshold_amount: decimal_to_string(near_limit_threshold),
                near_limit_ratio: near_limit_ratio.to_s("F"),
                near_limit_attempts_window_minutes: rule.near_limit_attempts_window_minutes,
                current_near_limit_attempts_count: recent_attempts
              }
            )
          end
        end
      end

      violations
    end

    def projected_usage(usage:, requested_amount:, net_amount:, stage:)
      return usage if stage.to_s == "confirm"

      Usage.new(
        daily_requested_amount: usage.daily_requested_amount + requested_amount,
        outstanding_exposure_amount: usage.outstanding_exposure_amount + net_amount,
        open_requests_count: usage.open_requests_count + 1
      )
    end

    def usage_for_scope(rule:, now:)
      cache_key = [ rule.scope_type, rule.scope_party_id.to_s, now.in_time_zone(BusinessCalendar.time_zone).to_date ]
      return @usage_cache.fetch(cache_key) if @usage_cache.key?(cache_key)

      scoped_requests = requests_for_scope(rule: rule)
      day_range = business_day_range(now)

      usage = Usage.new(
        daily_requested_amount: scoped_requests.where(status: DAILY_STATUSES, requested_at: day_range).sum(:requested_amount).to_d,
        outstanding_exposure_amount: scoped_requests.where(status: OPEN_STATUSES).sum(:net_amount).to_d,
        open_requests_count: scoped_requests.where(status: OPEN_STATUSES).count
      )

      @usage_cache[cache_key] = usage
      usage
    end

    def requests_for_scope(rule:)
      scope = AnticipationRequest.where(tenant_id: @tenant_id)

      case rule.scope_type
      when "TENANT_DEFAULT"
        scope
      when "PHYSICIAN_PARTY"
        scope
          .left_outer_joins(:receivable_allocation)
          .where(
            "anticipation_requests.requester_party_id = :party_id OR receivable_allocations.physician_party_id = :party_id",
            party_id: rule.scope_party_id
          )
      when "CNPJ_PARTY"
        party_ids = cnpj_party_ids_for_rule(rule)
        return scope.none if party_ids.empty?

        scope
          .left_outer_joins(:receivable_allocation)
          .joins(:receivable)
          .where(
            <<~SQL,
              anticipation_requests.requester_party_id IN (:party_ids)
              OR receivable_allocations.allocated_party_id IN (:party_ids)
              OR receivables.creditor_party_id IN (:party_ids)
              OR receivables.beneficiary_party_id IN (:party_ids)
            SQL
            party_ids: party_ids
          )
      when "HOSPITAL_PARTY"
        scope
          .joins(:receivable)
          .where(receivables: { debtor_party_id: rule.scope_party_id })
      else
        scope.none
      end
    end

    def build_violation(rule:, metric:, limit_value:, observed_value:, usage:, projected_usage:, extra_details: {})
      scope_label = SCOPE_LABELS.fetch(rule.scope_type)
      base_code = if rule.decision == "REVIEW"
        "risk_manual_review_required"
      else
        "risk_limit_exceeded_#{metric}"
      end

      Decision.new(
        allowed: decision_allows_request?(rule.decision),
        action: rule.decision,
        code: "#{base_code}_#{scope_label}",
        message: violation_message(rule:, metric:, scope_label: scope_label),
        rule: rule,
        metric: metric,
        scope_type: rule.scope_type,
        scope_party_id: rule.scope_party_id,
        details: {
          limit_value: decimal_to_string(limit_value),
          observed_value: decimal_to_string(observed_value),
          current_daily_requested_amount: decimal_to_string(usage.daily_requested_amount),
          projected_daily_requested_amount: decimal_to_string(projected_usage.daily_requested_amount),
          current_outstanding_exposure_amount: decimal_to_string(usage.outstanding_exposure_amount),
          projected_outstanding_exposure_amount: decimal_to_string(projected_usage.outstanding_exposure_amount),
          current_open_requests_count: usage.open_requests_count,
          projected_open_requests_count: projected_usage.open_requests_count
        }.merge(extra_details)
      )
    end

    def select_violation(violations)
      violations.max_by do |decision|
        [
          ACTION_SEVERITY.fetch(decision.action),
          -decision.rule.priority,
          decision.rule.created_at.to_i,
          decision.metric
        ]
      end
    end

    def violation_message(rule:, metric:, scope_label:)
      action_label = case rule.decision
      when "ALLOW"
        "was allowed under override"
      when "REVIEW"
        "requires manual review"
      else
        "was blocked"
      end

      "Anticipation request #{action_label} by #{scope_label} #{metric.tr('_', ' ')} rule."
    end

    def business_day_range(now)
      local_time = now.in_time_zone(BusinessCalendar.time_zone)
      local_date = local_time.to_date
      start_at = BusinessCalendar.time_zone.parse("#{local_date} 00:00:00")
      end_at = BusinessCalendar.cutoff_at(local_date)

      start_at..end_at
    end

    def advisory_lock!(key)
      quoted_key = ActiveRecord::Base.connection.quote(key)
      ActiveRecord::Base.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtext('anticipation_risk'), hashtext(#{quoted_key}))"
      )
    end

    def advisory_lock_keys(receivable:, receivable_allocation:, requester_party:, scope_map:, now:)
      keys = []
      keys << "#{@tenant_id}:tenant_default" if tenant_default_rules_active?(now)
      keys.concat(Array(scope_map["PHYSICIAN_PARTY"]).map { |party_id| "#{@tenant_id}:physician:#{party_id}" })
      keys.concat(Array(scope_map["HOSPITAL_PARTY"]).map { |party_id| "#{@tenant_id}:hospital:#{party_id}" })
      keys.concat(
        cnpj_scope_document_numbers(
          receivable: receivable,
          receivable_allocation: receivable_allocation,
          requester_party: requester_party
        ).map { |document_number| cnpj_lock_key(document_number) }
      )

      keys.compact.uniq.sort
    end

    def scope_key(scope_type)
      scope_type.to_s.downcase
    end

    def cnpj_scope_document_numbers(receivable:, receivable_allocation:, requester_party:)
      candidates = [
        requester_party,
        receivable_allocation&.allocated_party,
        receivable.creditor_party,
        receivable.beneficiary_party
      ].compact

      candidates
        .select { |party| party.document_type == "CNPJ" }
        .map(&:document_number)
        .compact_blank
        .uniq
    end

    def cnpj_party_ids_for_rule(rule)
      return [] if rule.scope_party_id.blank?

      @cnpj_party_ids_by_scope_party_id[rule.scope_party_id] ||= begin
        scope_party = Party.where(tenant_id: @tenant_id)
          .select(:id, :document_type, :document_number)
          .find_by(id: rule.scope_party_id)

        if scope_party.blank? || scope_party.document_type != "CNPJ" || scope_party.document_number.blank?
          [ rule.scope_party_id ]
        else
          cnpj_party_ids = cnpj_party_ids_for_document_number(scope_party.document_number)
          cnpj_party_ids.presence || [ rule.scope_party_id ]
        end
      end
    end

    def cnpj_party_ids_for_document_number(document_number)
      @cnpj_party_ids_by_document_number[document_number] ||= Party
        .where(tenant_id: @tenant_id, document_type: "CNPJ", document_number: document_number)
        .pluck(:id)
    end

    def velocity_counts_for_scope(rule:, now:)
      cache_key = [ rule.scope_type, rule.scope_party_id.to_s, now.to_i / 60 ]
      return @velocity_counts_cache.fetch(cache_key) if @velocity_counts_cache.key?(cache_key)

      scoped_requests = requests_for_scope(rule: rule)
      counts = {
        per_minute: scoped_requests.where(status: REQUEST_ACTIVITY_STATUSES)
          .where("requested_at >= ?", now - 1.minute).count,
        per_hour: scoped_requests.where(status: REQUEST_ACTIVITY_STATUSES)
          .where("requested_at >= ?", now - 1.hour).count
      }
      @velocity_counts_cache[cache_key] = counts
      counts
    end

    def pair_spike_metrics_for(receivable:, requester_party:, requested_amount:, stage:, now:)
      hospital_party_id = hospital_scope_party_id(receivable: receivable)
      return nil if hospital_party_id.blank?

      cache_key = [ requester_party.id, hospital_party_id, now.in_time_zone(BusinessCalendar.time_zone).to_date ]
      base_metrics = @pair_spike_cache[cache_key] ||= begin
        scope = AnticipationRequest.where(tenant_id: @tenant_id, requester_party_id: requester_party.id)
          .joins(:receivable)
          .where(receivables: { debtor_party_id: hospital_party_id })

        today_amount = scope.where(status: DAILY_STATUSES, requested_at: business_day_range(now)).sum(:requested_amount).to_d

        history_range = spike_history_range(now)
        historical_total = if history_range
          scope.where(status: DAILY_STATUSES, requested_at: history_range).sum(:requested_amount).to_d
        else
          BigDecimal("0")
        end

        {
          hospital_party_id: hospital_party_id,
          today_amount: today_amount,
          baseline_daily_amount: historical_total / BigDecimal(SPIKE_HISTORY_DAYS.to_s)
        }
      end

      projected_today_amount = base_metrics[:today_amount]
      projected_today_amount += requested_amount unless stage.to_s == "confirm"

      base_metrics.merge(projected_today_amount: projected_today_amount)
    end

    def spike_history_range(now)
      local_time = now.in_time_zone(BusinessCalendar.time_zone)
      local_date = local_time.to_date
      start_date = local_date - SPIKE_HISTORY_DAYS
      end_date = local_date - 1
      return nil if end_date < start_date

      start_at = BusinessCalendar.time_zone.parse("#{start_date} 00:00:00")
      end_at = BusinessCalendar.cutoff_at(end_date)
      start_at..end_at
    end

    def near_limit_attempts_count_for(requester_party_id:, window_minutes:, now:)
      cache_key = [ requester_party_id, window_minutes, now.to_i / 60 ]
      return @near_limit_attempts_cache.fetch(cache_key) if @near_limit_attempts_cache.key?(cache_key)

      count = AnticipationRiskDecision.where(
        tenant_id: @tenant_id,
        requester_party_id: requester_party_id,
        stage: "CREATE",
        decision_action: "BLOCK"
      ).where("evaluated_at >= ?", now - window_minutes.minutes)
        .where("decision_metric = ? OR decision_code LIKE ?", "single_request", "risk_limit_exceeded_single_request%")
        .count

      @near_limit_attempts_cache[cache_key] = count
      count
    end

    def tenant_default_rules_active?(now)
      AnticipationRiskRule.where(tenant_id: @tenant_id, scope_type: "TENANT_DEFAULT", active: true)
        .where("effective_from IS NULL OR effective_from <= ?", now)
        .where("effective_until IS NULL OR effective_until >= ?", now)
        .exists?
    end

    def cnpj_lock_key(document_number)
      digest = Digest::SHA256.hexdigest(document_number.to_s)
      "#{@tenant_id}:cnpj_sha256:#{digest[0, 16]}"
    end

    def decision_allows_request?(decision_action)
      decision_action == "ALLOW"
    end

    def decimal_to_string(value)
      return format("%.2f", value.to_d) if value.is_a?(BigDecimal)
      return format("%.2f", BigDecimal(value.to_s)) if value.is_a?(Numeric)

      value.to_s
    end
  end
end
