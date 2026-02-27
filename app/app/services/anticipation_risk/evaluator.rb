module AnticipationRisk
  class Evaluator
    OPEN_STATUSES = %w[REQUESTED APPROVED FUNDED].freeze
    DAILY_STATUSES = %w[REQUESTED APPROVED FUNDED SETTLED].freeze
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
    end

    def evaluate!(receivable:, receivable_allocation:, requester_party:, requested_amount:, net_amount:, stage:)
      now = Time.current
      lock_scope = lock_scope_key(receivable:, receivable_allocation:, requester_party:)
      advisory_lock!(lock_scope)

      rules = applicable_rules(
        receivable: receivable,
        receivable_allocation: receivable_allocation,
        requester_party: requester_party,
        now: now
      )
      return allow_decision if rules.empty?

      violations = rules.flat_map do |rule|
        evaluate_rule(
          rule: rule,
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

    def applicable_rules(receivable:, receivable_allocation:, requester_party:, now:)
      scope_map = scope_map(receivable:, receivable_allocation:, requester_party:)
      rule_scope = AnticipationRiskRule.where(tenant_id: @tenant_id).active
      rule_scope = rule_scope.where("effective_from IS NULL OR effective_from <= ?", now)
      rule_scope = rule_scope.where("effective_until IS NULL OR effective_until >= ?", now)

      scope_conditions = []
      scope_values = {}

      scope_map.each do |scope_type, scope_party_id|
        type_key = :"#{scope_key(scope_type)}_type"
        party_key = :"#{scope_key(scope_type)}_party_id"

        if scope_party_id.nil?
          scope_conditions << "(scope_type = :#{type_key} AND scope_party_id IS NULL)"
          scope_values[type_key] = scope_type
          next
        end

        scope_conditions << "(scope_type = :#{type_key} AND scope_party_id = :#{party_key})"
        scope_values[type_key] = scope_type
        scope_values[party_key] = scope_party_id
      end

      return [] if scope_conditions.empty?

      rule_scope.where(scope_conditions.join(" OR "), scope_values)
        .order(priority: :asc, created_at: :asc)
        .to_a
    end

    def scope_map(receivable:, receivable_allocation:, requester_party:)
      map = { "TENANT_DEFAULT" => nil }

      physician_party_id = physician_scope_party_id(receivable_allocation:, requester_party:)
      map["PHYSICIAN_PARTY"] = physician_party_id if physician_party_id.present?

      cnpj_party_id = cnpj_scope_party_id(receivable:, receivable_allocation:, requester_party:)
      map["CNPJ_PARTY"] = cnpj_party_id if cnpj_party_id.present?

      hospital_party_id = hospital_scope_party_id(receivable: receivable)
      map["HOSPITAL_PARTY"] = hospital_party_id if hospital_party_id.present?

      map
    end

    def physician_scope_party_id(receivable_allocation:, requester_party:)
      allocation_party_id = receivable_allocation&.physician_party_id
      return allocation_party_id if allocation_party_id.present?
      return requester_party.id if requester_party.kind == "PHYSICIAN_PF"

      nil
    end

    def cnpj_scope_party_id(receivable:, receivable_allocation:, requester_party:)
      candidates = [
        requester_party,
        receivable_allocation&.allocated_party,
        receivable.creditor_party,
        receivable.beneficiary_party
      ].compact

      candidates.find { |party| party.document_type == "CNPJ" }&.id
    end

    def hospital_scope_party_id(receivable:)
      return receivable.debtor_party_id if receivable.debtor_party&.kind == "HOSPITAL"

      nil
    end

    def evaluate_rule(rule:, requested_amount:, net_amount:, stage:, now:)
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
        scope
          .left_outer_joins(:receivable_allocation)
          .joins(:receivable)
          .where(
            <<~SQL,
              anticipation_requests.requester_party_id = :party_id
              OR receivable_allocations.allocated_party_id = :party_id
              OR receivables.creditor_party_id = :party_id
              OR receivables.beneficiary_party_id = :party_id
            SQL
            party_id: rule.scope_party_id
          )
      when "HOSPITAL_PARTY"
        scope
          .joins(:receivable)
          .where(receivables: { debtor_party_id: rule.scope_party_id })
      else
        scope.none
      end
    end

    def build_violation(rule:, metric:, limit_value:, observed_value:, usage:, projected_usage:)
      scope_label = SCOPE_LABELS.fetch(rule.scope_type)
      base_code = if rule.decision == "REVIEW"
        "risk_manual_review_required"
      else
        "risk_limit_exceeded_#{metric}"
      end

      Decision.new(
        allowed: false,
        action: rule.decision,
        code: "#{base_code}_#{scope_label}",
        message: violation_message(rule:, metric:, limit_value:, observed_value:, scope_label: scope_label),
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
        }
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

    def violation_message(rule:, metric:, limit_value:, observed_value:, scope_label:)
      action_label = rule.decision == "REVIEW" ? "requires manual review" : "was blocked"
      "Anticipation request #{action_label} by #{scope_label} #{metric.tr('_', ' ')} limit: observed #{decimal_to_string(observed_value)} exceeds #{decimal_to_string(limit_value)}."
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

    def lock_scope_key(receivable:, receivable_allocation:, requester_party:)
      [
        @tenant_id,
        receivable.id,
        receivable_allocation&.id,
        requester_party.id
      ].join(":")
    end

    def scope_key(scope_type)
      scope_type.to_s.downcase
    end

    def decimal_to_string(value)
      return format("%.2f", value.to_d) if value.is_a?(BigDecimal)
      return format("%.2f", BigDecimal(value.to_s)) if value.is_a?(Numeric)

      value.to_s
    end
  end
end
