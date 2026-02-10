class DashboardController < ApplicationController
  STAGE_DEFINITIONS = [
    { key: :performed, label: "Recebível performado" },
    { key: :requested, label: "Antecipação solicitada" },
    { key: :challenge_issued, label: "Confirmação enviada" },
    { key: :signed, label: "Documento assinado" },
    { key: :funded, label: "Antecipação aprovada/fundada" },
    { key: :settled, label: "Pagamento liquidado" }
  ].freeze

  EVENT_LABELS = {
    "RECEIVABLE_IMPORTED" => "Recebível importado",
    "RECEIVABLE_PERFORMED" => "Recebível performado",
    "ANTICIPATION_REQUESTED" => "Antecipação solicitada",
    "ANTICIPATION_CONFIRMATION_CHALLENGES_ISSUED" => "Códigos de confirmação enviados",
    "ANTICIPATION_CONFIRMED" => "Antecipação confirmada",
    "ANTICIPATION_FUNDED" => "Antecipação fundada",
    "RECEIVABLE_PAYMENT_SETTLED" => "Pagamento liquidado"
  }.freeze

  helper_method :fdic_persona?, :stage_definitions, :persona_title

  def show
    @persona = resolve_persona
    @receivables = scoped_receivables
      .includes(:receivable_kind, :debtor_party, :creditor_party, :beneficiary_party)
      .order(performed_at: :desc)
      .limit(100)
      .to_a

    @receivable_ids = @receivables.map(&:id)

    @anticipation_requests = scoped_anticipation_requests
      .includes(:requester_party, :receivable, :anticipation_settlement_entries)
      .order(requested_at: :desc)
      .limit(200)
      .to_a

    @anticipations_by_receivable = @anticipation_requests.group_by(&:receivable_id)
    @settlements_by_receivable = load_settlements_by_receivable
    @documents_by_receivable = load_documents_by_receivable
    @events_by_receivable = load_events_by_receivable
    @challenges_by_anticipation = load_challenges_by_anticipation

    @stage_rows = @receivables.map { |receivable| stage_row_for(receivable) }
    @stage_completion = build_stage_completion(@stage_rows)
    @headline_cards = build_headline_cards

    @selected_receivable = select_receivable
    @timeline_entries = @selected_receivable ? timeline_entries_for(@selected_receivable) : []

    @fdic_anticipation_rows = fdic_persona? ? build_fdic_anticipation_rows : []
    @daily_statistics = fdic_persona? ? load_daily_statistics : []
  end

  private

  def stage_definitions
    STAGE_DEFINITIONS
  end

  def persona_title
    case @persona
    when :hospital
      "Visão do Hospital"
    when :supplier
      "Visão do Fornecedor"
    when :physician
      "Visão do Médico"
    when :fdic
      "Visão do FDIC"
    else
      "Visão Operacional"
    end
  end

  def fdic_persona?
    @persona == :fdic
  end

  def resolve_persona
    return :fdic if Current.user&.party&.kind == "FIDC"

    case Current.user&.role
    when "hospital_admin"
      :hospital
    when "supplier_user"
      :supplier
    when "physician_pf_user", "physician_pj_admin", "physician_pj_member"
      :physician
    when "ops_admin"
      :fdic
    else
      :operations
    end
  end

  def current_tenant_id
    Current.user&.tenant_id
  end

  def current_party_id
    Current.user&.party_id
  end

  def scoped_receivables
    base = Receivable.where(tenant_id: current_tenant_id)

    case @persona
    when :hospital
      base.where(debtor_party_id: current_party_id)
    when :supplier
      base.where(
        "creditor_party_id = :party_id OR beneficiary_party_id = :party_id",
        party_id: current_party_id
      )
    when :physician
      receivable_ids = ReceivableAllocation.where(
        tenant_id: current_tenant_id,
        physician_party_id: current_party_id
      ).select(:receivable_id)
      base.where(id: receivable_ids)
    else
      base
    end
  end

  def scoped_anticipation_requests
    base = AnticipationRequest.where(tenant_id: current_tenant_id)

    case @persona
    when :hospital
      base.where(receivable_id: scoped_receivables.select(:id))
    when :supplier, :physician
      base.where(requester_party_id: current_party_id)
    else
      base
    end
  end

  def load_settlements_by_receivable
    ReceivablePaymentSettlement
      .where(tenant_id: current_tenant_id, receivable_id: @receivable_ids)
      .includes(:anticipation_settlement_entries)
      .order(paid_at: :asc)
      .group_by(&:receivable_id)
  end

  def load_documents_by_receivable
    Document
      .where(tenant_id: current_tenant_id, receivable_id: @receivable_ids)
      .includes(:document_events)
      .order(signed_at: :asc)
      .group_by(&:receivable_id)
  end

  def load_events_by_receivable
    ReceivableEvent
      .where(tenant_id: current_tenant_id, receivable_id: @receivable_ids)
      .order(sequence: :asc)
      .group_by(&:receivable_id)
  end

  def load_challenges_by_anticipation
    anticipation_ids = @anticipation_requests.map(&:id)
    return {} if anticipation_ids.empty?

    AuthChallenge
      .where(tenant_id: current_tenant_id, target_type: "AnticipationRequest", target_id: anticipation_ids)
      .order(created_at: :asc)
      .group_by(&:target_id)
  end

  def select_receivable
    selected_id = params[:receivable_id].to_s
    return @receivables.first if selected_id.blank?

    @receivables.find { |receivable| receivable.id == selected_id } || @receivables.first
  end

  def stage_row_for(receivable)
    anticipation_requests = @anticipations_by_receivable.fetch(receivable.id, [])
    receivable_events = @events_by_receivable.fetch(receivable.id, [])
    documents = @documents_by_receivable.fetch(receivable.id, [])
    settlements = @settlements_by_receivable.fetch(receivable.id, [])

    has_challenges = anticipation_requests.any? do |entry|
      @challenges_by_anticipation.fetch(entry.id, []).any?
    end

    stage_state = {
      performed: true,
      requested: anticipation_requests.any?,
      challenge_issued: has_challenges || receivable_events.any? { |event| event.event_type == "ANTICIPATION_CONFIRMATION_CHALLENGES_ISSUED" },
      signed: documents.any? { |document| document.status == "SIGNED" },
      funded: receivable.status.in?(%w[FUNDED SETTLED]) || anticipation_requests.any? { |entry| entry.status.in?(%w[APPROVED FUNDED SETTLED]) },
      settled: receivable.status == "SETTLED" || settlements.any?
    }

    last_update_at = [
      receivable.updated_at,
      receivable_events.last&.occurred_at,
      documents.last&.signed_at,
      settlements.last&.paid_at,
      anticipation_requests.last&.updated_at
    ].compact.max

    {
      receivable: receivable,
      stages: stage_state,
      completed_count: stage_state.values.count(true),
      last_update_at: last_update_at
    }
  end

  def build_stage_completion(stage_rows)
    total = stage_rows.size

    STAGE_DEFINITIONS.each_with_object({}) do |stage, output|
      completed = stage_rows.count { |row| row[:stages][stage[:key]] }
      percentage = total.zero? ? 0.0 : ((completed.to_f / total) * 100)

      output[stage[:key]] = {
        completed: completed,
        total: total,
        percentage: percentage
      }
    end
  end

  def timeline_entries_for(receivable)
    receivable_entries = []

    @events_by_receivable.fetch(receivable.id, []).each do |event|
      receivable_entries << {
        happened_at: event.occurred_at,
        category: "Evento",
        title: EVENT_LABELS.fetch(event.event_type, event.event_type.humanize),
        details: "Sequência #{event.sequence} · #{event.actor_role.presence || "sistema"}",
        payload: event.payload
      }
    end

    @documents_by_receivable.fetch(receivable.id, []).each do |document|
      receivable_entries << {
        happened_at: document.signed_at,
        category: "Documento",
        title: "Documento assinado (#{document.document_type})",
        details: "Método: #{document.signature_method}",
        payload: document.metadata
      }

      document.document_events.each do |event|
        receivable_entries << {
          happened_at: event.occurred_at,
          category: "Documento",
          title: event.event_type.humanize,
          details: "Evento documental",
          payload: event.payload
        }
      end
    end

    @settlements_by_receivable.fetch(receivable.id, []).each do |settlement|
      receivable_entries << {
        happened_at: settlement.paid_at,
        category: "Liquidação",
        title: "Pagamento liquidado",
        details: "Valor pago #{format_brl(settlement.paid_amount)}",
        payload: settlement.metadata
      }
    end

    @anticipations_by_receivable.fetch(receivable.id, []).each do |anticipation|
      challenge_count = @challenges_by_anticipation.fetch(anticipation.id, []).size
      receivable_entries << {
        happened_at: anticipation.requested_at,
        category: "Antecipação",
        title: "Solicitação de antecipação",
        details: "Status #{human_status(anticipation.status)} · #{challenge_count} desafio(s) de confirmação",
        payload: anticipation.metadata
      }
    end

    receivable_entries.sort_by { |entry| entry[:happened_at] || Time.at(0) }
  end

  def build_headline_cards
    total_gross = @receivables.sum { |entry| entry.gross_amount.to_d }
    total_requested = @anticipation_requests.sum { |entry| entry.requested_amount.to_d }
    total_discount = @anticipation_requests.sum { |entry| entry.discount_amount.to_d }
    total_net = @anticipation_requests.sum { |entry| entry.net_amount.to_d }
    total_settled = @settlements_by_receivable.values.flatten.sum { |entry| entry.paid_amount.to_d }
    settled_requests = @anticipation_requests.count { |entry| entry.status == "SETTLED" }
    settled_ratio = @anticipation_requests.empty? ? BigDecimal("0") : BigDecimal(settled_requests.to_s) / BigDecimal(@anticipation_requests.size.to_s)

    case @persona
    when :fdic
      [
        { label: "Carteira performada", value: total_gross, kind: :money, footnote: "#{@receivables.size} recebíveis no escopo" },
        { label: "Volume antecipado", value: total_requested, kind: :money, footnote: "#{@anticipation_requests.size} solicitações" },
        { label: "Retorno em desconto", value: total_discount, kind: :money, footnote: "Spread acumulado" },
        { label: "Efetivação das antecipações", value: settled_ratio, kind: :percentage, footnote: "#{settled_requests} liquidadas" }
      ]
    when :hospital
      pending_count = @receivables.count { |entry| entry.status.in?(%w[PERFORMED ANTICIPATION_REQUESTED]) }
      [
        { label: "Recebíveis do hospital", value: total_gross, kind: :money, footnote: "#{@receivables.size} recebíveis" },
        { label: "Antecipações em andamento", value: pending_count, kind: :integer, footnote: "Fluxos ainda abertos" },
        { label: "Valor líquido contratado", value: total_net, kind: :money, footnote: "Após desconto e encargos" },
        { label: "Pagamentos liquidados", value: total_settled, kind: :money, footnote: "Repasse confirmado" }
      ]
    when :supplier, :physician
      in_progress = @anticipation_requests.count { |entry| entry.status.in?(%w[REQUESTED APPROVED FUNDED]) }
      [
        { label: "Minha carteira elegível", value: total_gross, kind: :money, footnote: "#{@receivables.size} recebíveis vinculados" },
        { label: "Solicitado para antecipação", value: total_requested, kind: :money, footnote: "#{@anticipation_requests.size} solicitações" },
        { label: "Valor líquido esperado", value: total_net, kind: :money, footnote: "Projeção líquida" },
        { label: "Solicitações em andamento", value: in_progress, kind: :integer, footnote: "Aguardando etapa seguinte" }
      ]
    else
      [
        { label: "Carteira acompanhada", value: total_gross, kind: :money, footnote: "#{@receivables.size} recebíveis" },
        { label: "Antecipações", value: total_requested, kind: :money, footnote: "#{@anticipation_requests.size} solicitações" },
        { label: "Desconto acumulado", value: total_discount, kind: :money, footnote: "Resultado financeiro" },
        { label: "Liquidação", value: total_settled, kind: :money, footnote: "Pagamentos concluídos" }
      ]
    end
  end

  def build_fdic_anticipation_rows
    calculator = Fdic::ExposureCalculator.new(valuation_time: Time.current)

    @anticipation_requests.map do |anticipation|
      receivable = anticipation.receivable
      exposure_metrics = calculator.call(anticipation_request: anticipation, due_at: receivable&.due_at)

      {
        anticipation: anticipation,
        receivable: receivable,
        requester: anticipation.requester_party,
        obligation: exposure_metrics.contractual_obligation,
        exposure: exposure_metrics.effective_contractual_exposure,
        term_days: exposure_metrics.term_business_days,
        yield_rate: if anticipation.requested_amount.to_d.positive?
          anticipation.discount_amount.to_d / anticipation.requested_amount.to_d
        else
          BigDecimal("0")
        end
      }
    end
  end

  def load_daily_statistics
    ReceivableDailyStatistic
      .where(tenant_id: current_tenant_id, metric_scope: "GLOBAL")
      .includes(:receivable_kind)
      .order(stat_date: :desc)
      .limit(14)
      .to_a
  end

  def human_status(value)
    key = value.to_s.downcase.strip.tr(" -", "__")
    ApplicationHelper::STATUS_LABELS.fetch(key, key.tr("_", " ").capitalize)
  end
end
