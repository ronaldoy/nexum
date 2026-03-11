module Admin
  class FidcCockpit
    PROFITABILITY_ACTION = "FIDC_PROFITABILITY_RECORDED".freeze
    PROFITABILITY_ENTRY_KINDS = %w[INCOME EXPENSE].freeze
    ACTIVE_LOAN_STATUSES = %w[REQUESTED PENDING_REVIEW APPROVED FUNDED].freeze
    LOAN_STRUCTURE_FILTER_KINDS = {
      "pf" => "PHYSICIAN_PF",
      "pj" => "LEGAL_ENTITY_PJ"
    }.freeze
    ZERO = BigDecimal("0")
    STAGE_DEFINITIONS = [
      { key: :requested, label: "Solicitado" },
      { key: :signed, label: "Contrato assinado" },
      { key: :approved, label: "Aprovado" },
      { key: :funded, label: "Funded" },
      { key: :settled, label: "Liquidado" }
    ].freeze
    STAGE_TONES = {
      requested: { tone: "#64748b", tone_soft: "rgba(100, 116, 139, 0.7)" },
      signed: { tone: "#f59e0b", tone_soft: "rgba(245, 158, 11, 0.72)" },
      approved: { tone: "#2563eb", tone_soft: "rgba(37, 99, 235, 0.7)" },
      funded: { tone: "#06b6d4", tone_soft: "rgba(6, 182, 212, 0.72)" },
      settled: { tone: "#16a34a", tone_soft: "rgba(22, 163, 74, 0.72)" }
    }.freeze

    def initialize(tenant:)
      @tenant = tenant
    end

    def call(recent_limit: 8, recent_page: 1, recent_structure: nil)
      recent_loan_page = paginated_loan_rows(page: recent_page, per_page: recent_limit, structure: recent_structure)

      {
        generated_at: Time.current,
        tenant: tenant,
        headline_cards: headline_cards,
        stage_cards: stage_cards,
        stage_volume_chart: stage_volume_chart,
        commercial_highlights: commercial_highlights,
        recent_loans: recent_loan_page.fetch(:rows),
        recent_loans_pagination: recent_loan_page.fetch(:pagination),
        counterparty_rows: counterparty_rows,
        profitability_entries: profitability_entries(limit: 12),
        risk_signals: risk_signals(limit: 8),
        reconciliation_exceptions: reconciliation_exceptions(limit: 8)
      }
    end

    def loan_rows(limit: 50, structure: nil)
      scope = filtered_anticipation_scope(structure)
      scope = scope.limit(limit) if limit.present?
      scope.map { |anticipation| build_loan_row(anticipation) }
    end

    def paginated_loan_rows(page:, per_page:, structure: nil)
      scope = filtered_anticipation_scope(structure)
      total_count = scope.count
      per_page_value = [ per_page.to_i, 1 ].max
      total_pages = total_count.zero? ? 1 : (total_count.to_f / per_page_value).ceil
      current_page = [ page.to_i, 1 ].max
      current_page = [ current_page, total_pages ].min
      offset = (current_page - 1) * per_page_value
      rows = scope.offset(offset).limit(per_page_value).map { |anticipation| build_loan_row(anticipation) }
      from = total_count.zero? ? 0 : offset + 1
      to = total_count.zero? ? 0 : offset + rows.length

      {
        rows: rows,
        pagination: {
          page: current_page,
          per_page: per_page_value,
          total_count: total_count,
          total_pages: total_pages,
          from: from,
          to: to,
          prev_page: current_page > 1 ? current_page - 1 : nil,
          next_page: current_page < total_pages ? current_page + 1 : nil
        }
      }
    end

    def loan_row(anticipation_request)
      build_loan_row(anticipation_request)
    end

    def profitability_entries(limit: 20)
      profitability_logs
        .first(limit)
        .map { |log| profitability_entry(log) }
    end

    def stage_cards
      total_operations = portfolio_loan_rows.count

      STAGE_DEFINITIONS.map do |stage|
        completed = portfolio_loan_rows.count { |row| row[:stages].fetch(stage[:key]) }
        {
          label: stage.fetch(:label),
          completed: completed,
          total: total_operations
        }
      end
    end

    def stage_volume_chart
      total_requested_volume = commercial_highlights.fetch(:requested_volume)

      STAGE_DEFINITIONS.map do |stage|
        rows = portfolio_loan_rows.select { |row| row[:stages].fetch(stage[:key]) }
        volume = rows.sum(BigDecimal("0")) { |row| stage_volume_amount(row:, stage_key: stage[:key]) }
        count = rows.count
        average_ticket = count.positive? ? (volume / count) : BigDecimal("0")
        ratio = total_requested_volume.positive? ? (volume / total_requested_volume) : BigDecimal("0")
        palette = STAGE_TONES.fetch(stage[:key])

        {
          key: stage[:key],
          label: stage[:label],
          volume: volume,
          count: count,
          average_ticket: average_ticket,
          ratio: ratio,
          tone: palette.fetch(:tone),
          tone_soft: palette.fetch(:tone_soft)
        }
      end
    end

    private

    attr_reader :tenant

    def headline_cards
      highlights = commercial_highlights

      [
        {
          label: "Contrapartes",
          value: parties_scope.count,
          footnote: "#{hospital_count} hospitais, #{physician_count} médicos"
        },
        {
          label: "Empréstimos ativos",
          value: active_loan_count,
          footnote: "#{funded_loan_count} já em Funded"
        },
        {
          label: "Exposição aberta",
          value: highlights.fetch(:open_exposure),
          footnote: "Principal ainda não retornado em operações expostas",
          kind: :money
        },
        {
          label: "Lucro estimado",
          value: highlights.fetch(:estimated_profit),
          footnote: "#{highlights.fetch(:unsettled_count)} operações ainda abertas",
          kind: :money
        },
        {
          label: "Lucro realizado",
          value: highlights.fetch(:realized_profit),
          footnote: "#{highlights.fetch(:fully_liquidated_count)} operações totalmente liquidadas",
          kind: :money
        },
        {
          label: "Volume liquidado",
          value: highlights.fetch(:settled_volume),
          footnote: "Principal já recuperado pela carteira",
          kind: :money
        },
        {
          label: "Vencendo em 7 dias",
          value: due_soon_count,
          footnote: "Operações com vencimento próximo"
        }
      ]
    end

    def commercial_highlights
      @commercial_highlights ||= begin
        rows = portfolio_loan_rows
        requested_volume = rows.sum(BigDecimal("0")) { |row| row[:requested_amount] }
        funded_rows = rows.select { |row| row[:stages].fetch(:funded) }
        settled_rows = rows.select { |row| row[:fully_liquidated] }
        funded_volume = funded_rows.sum(BigDecimal("0")) { |row| row[:requested_amount] }
        settled_volume = settled_rows.sum(BigDecimal("0")) { |row| row[:requested_amount] }
        open_exposure = rows.sum(BigDecimal("0")) { |row| row[:open_exposure] }
        estimated_profit = rows.sum(BigDecimal("0")) { |row| row[:estimated_profit] }
        realized_profit = rows.sum(BigDecimal("0")) { |row| row[:realized_profit] }
        due_soon_exposure = rows.select { |row| row[:days_to_due].between?(0, 7) }.sum(BigDecimal("0")) { |row| row[:open_exposure] }
        average_ticket = rows.any? ? (requested_volume / rows.size) : BigDecimal("0")
        blended_yield_rate = requested_volume.positive? ? (rows.sum(BigDecimal("0")) { |row| row[:discount_amount] } / requested_volume) : BigDecimal("0")
        average_term_days = rows.any? ? (rows.sum(0) { |row| row[:term_days] }.to_d / rows.size) : BigDecimal("0")
        funded_conversion_rate = requested_volume.positive? ? (funded_volume / requested_volume) : BigDecimal("0")
        fully_liquidated_count = settled_rows.count
        unsettled_count = rows.count - fully_liquidated_count

        {
          operations_count: rows.size,
          requested_volume: requested_volume,
          funded_volume: funded_volume,
          settled_volume: settled_volume,
          open_exposure: open_exposure,
          estimated_profit: estimated_profit,
          realized_profit: realized_profit,
          due_soon_exposure: due_soon_exposure,
          average_ticket: average_ticket,
          blended_yield_rate: blended_yield_rate,
          average_term_days: average_term_days,
          funded_conversion_rate: funded_conversion_rate,
          fully_liquidated_count: fully_liquidated_count,
          unsettled_count: unsettled_count
        }
      end
    end

    def active_loan_count
      anticipation_scope.where(status: ACTIVE_LOAN_STATUSES).count
    end

    def funded_loan_count
      anticipation_scope.where(status: %w[APPROVED FUNDED]).count
    end

    def due_soon_count
      receivable_scope.where(due_at: Time.current..7.days.from_now).count
    end

    def hospital_count
      parties_scope.where(kind: "HOSPITAL").count
    end

    def physician_count
      parties_scope.where(kind: "PHYSICIAN_PF").count
    end

    def counterparty_rows
      parties_scope
        .order(created_at: :desc)
        .limit(8)
        .map do |party|
          {
            party: party,
            active_loans_count: active_loans_for_party(party.id),
            settled_loans_count: settled_loans_for_party(party.id)
          }
        end
    end

    def profitability_logs
      @profitability_logs ||= ActionIpLog
        .where(
          tenant_id: tenant.id,
          action_type: PROFITABILITY_ACTION,
          target_type: "AnticipationRequest",
          success: true
        )
        .order(occurred_at: :desc, created_at: :desc)
        .to_a
    end

    def profitability_groups
      @profitability_groups ||= profitability_logs.group_by { |log| log.target_id.to_s }
    end

    def profitability_entry(log)
      metadata = log.metadata || {}
      {
        id: log.id,
        anticipation_request_id: log.target_id,
        occurred_at: log.occurred_at,
        entry_kind: metadata["entry_kind"],
        category: metadata["category"],
        note: metadata["note"],
        amount: decimal_metadata(metadata["amount"]),
        actor_party_id: log.actor_party_id
      }
    end

    def profitability_totals_for(anticipation_request_id)
      entries = profitability_groups.fetch(anticipation_request_id.to_s, []).map { |log| profitability_entry(log) }
      income = entries.select { |entry| entry[:entry_kind] == "INCOME" }.sum(BigDecimal("0")) { |entry| entry[:amount] }
      expense = entries.select { |entry| entry[:entry_kind] == "EXPENSE" }.sum(BigDecimal("0")) { |entry| entry[:amount] }

      {
        entries: entries,
        income: income,
        expense: expense,
        net: income - expense
      }
    end

    def build_loan_row(anticipation)
      receivable = anticipation.receivable
      allocation = anticipation.receivable_allocation
      exposure = exposure_calculator.call(anticipation_request: anticipation, due_at: receivable.due_at)
      profitability = profitability_totals_for(anticipation.id)
      documents_count = documents_by_receivable.fetch(receivable.id.to_s, []).size
      settlement_total = settlement_totals.fetch(anticipation.id.to_s, BigDecimal("0"))
      fully_liquidated = fully_liquidated?(anticipation:, exposure:, settlement_total:)
      total_profitability = anticipation.discount_amount.to_d + profitability[:net]

      {
        anticipation: anticipation,
        receivable: receivable,
        allocation: allocation,
        requester: anticipation.requester_party,
        allocated_party: allocation&.allocated_party,
        physician_party: allocation&.physician_party,
        debtor: receivable.debtor_party,
        documents_count: documents_count,
        fidc_operations_count: fidc_operations_by_request.fetch(anticipation.id.to_s, []).size,
        current_stage: current_stage_for(anticipation:, documents_count:, settlement_total:, fully_liquidated:),
        stages: stage_state_for(anticipation:, documents_count:, settlement_total:, fully_liquidated:),
        due_at: receivable.due_at,
        term_days: [(receivable.due_at.to_date - receivable.performed_at.to_date).to_i, 0].max,
        days_to_due: (receivable.due_at.to_date - Time.zone.today).to_i,
        gross_amount: receivable.gross_amount.to_d,
        requested_amount: anticipation.requested_amount.to_d,
        net_amount: anticipation.net_amount.to_d,
        discount_amount: anticipation.discount_amount.to_d,
        settlement_total: settlement_total,
        fully_liquidated: fully_liquidated,
        open_exposure: dashboard_open_exposure_for(exposure:, fully_liquidated:),
        exposure_term_business_days: exposure.term_business_days,
        exposure_elapsed_business_days: exposure.elapsed_business_days,
        yield_rate: safe_division(anticipation.discount_amount, anticipation.requested_amount),
        profitability_income: profitability[:income],
        profitability_expense: profitability[:expense],
        profitability_adjustment: profitability[:net],
        estimated_profit: fully_liquidated ? ZERO : total_profitability,
        realized_profit: fully_liquidated ? total_profitability : ZERO,
        recorded_profitability: total_profitability,
        profitability_entries: profitability[:entries]
      }
    end

    def portfolio_loan_rows
      @portfolio_loan_rows ||= loan_rows(limit: nil)
    end

    def filtered_anticipation_scope(structure)
      normalized_filter = normalize_structure_filter(structure)
      return anticipation_scope unless normalized_filter.present?

      anticipation_scope.where(
        requester_party_id: parties_scope.where(kind: LOAN_STRUCTURE_FILTER_KINDS.fetch(normalized_filter)).select(:id)
      )
    end

    def stage_volume_amount(row:, stage_key:)
      row[:requested_amount]
    end

    def current_stage_for(anticipation:, documents_count:, settlement_total:, fully_liquidated:)
      return "Liquidado" if fully_liquidated
      return "Liquidação parcial" if settlement_total.positive?
      return "Funded" if anticipation.status == "FUNDED"
      return "Aprovado" if anticipation.status == "APPROVED"
      return "Contrato assinado" if documents_count.positive?

      "Solicitado"
    end

    def stage_state_for(anticipation:, documents_count:, settlement_total:, fully_liquidated:)
      {
        requested: true,
        signed: documents_count.positive?,
        approved: anticipation.status.in?(%w[APPROVED FUNDED SETTLED]),
        funded: anticipation.status.in?(%w[FUNDED SETTLED]),
        settled: fully_liquidated
      }
    end

    def dashboard_open_exposure_for(exposure:, fully_liquidated:)
      return ZERO if fully_liquidated

      positive_money(exposure.effective_contractual_exposure)
    end

    def fully_liquidated?(anticipation:, exposure:, settlement_total:)
      anticipation.status == "SETTLED" || settlement_total >= exposure.contractual_obligation
    end

    def settlement_totals
      @settlement_totals ||= AnticipationSettlementEntry
        .where(tenant_id: tenant.id)
        .group(:anticipation_request_id)
        .sum(:settled_amount)
        .transform_keys(&:to_s)
        .transform_values(&:to_d)
    end

    def documents_by_receivable
      @documents_by_receivable ||= Document
        .where(tenant_id: tenant.id)
        .order(signed_at: :desc)
        .group_by { |document| document.receivable_id.to_s }
    end

    def fidc_operations_by_request
      @fidc_operations_by_request ||= FidcOperation
        .where(tenant_id: tenant.id)
        .order(requested_at: :desc)
        .group_by { |operation| operation.anticipation_request_id.to_s }
    end

    def risk_signals(limit:)
      AnticipationRiskDecision
        .where(tenant_id: tenant.id, decision_action: %w[REVIEW BLOCK])
        .includes(:requester_party, :anticipation_request)
        .order(evaluated_at: :desc)
        .limit(limit)
    end

    def reconciliation_exceptions(limit:)
      ReconciliationException
        .where(tenant_id: tenant.id, status: "OPEN")
        .order(last_seen_at: :desc)
        .limit(limit)
    end

    def active_loans_for_party(party_id)
      anticipation_scope
        .where(requester_party_id: party_id, status: ACTIVE_LOAN_STATUSES)
        .count
    end

    def settled_loans_for_party(party_id)
      anticipation_scope
        .where(requester_party_id: party_id, status: "SETTLED")
        .count
    end

    def anticipation_scope
      @anticipation_scope ||= AnticipationRequest
        .where(tenant_id: tenant.id)
        .includes(
          :requester_party,
          receivable_allocation: %i[allocated_party physician_party],
          receivable: %i[debtor_party creditor_party beneficiary_party receivable_kind]
        )
        .order(requested_at: :desc, created_at: :desc)
    end

    def normalize_structure_filter(value)
      candidate = value.to_s
      return nil unless LOAN_STRUCTURE_FILTER_KINDS.key?(candidate)

      candidate
    end

    def receivable_scope
      @receivable_scope ||= Receivable.where(tenant_id: tenant.id)
    end

    def parties_scope
      @parties_scope ||= Party.where(tenant_id: tenant.id)
    end

    def exposure_calculator
      @exposure_calculator ||= Fidc::ExposureCalculator.new(valuation_time: Time.current)
    end

    def decimal_metadata(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end

    def safe_division(numerator, denominator)
      denominator_value = denominator.to_d
      return BigDecimal("0") if denominator_value.zero?

      numerator.to_d / denominator_value
    end

    def positive_money(value)
      [ value.to_d, ZERO ].max
    end
  end
end
