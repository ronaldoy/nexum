class DashboardController < ApplicationController
  include ReceivableProvenancePayload

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
    load_dashboard_collections
    load_receivable_relationship_indexes
    build_dashboard_overview
    build_selected_receivable_timeline
    load_fdic_data
  end

  private

  def load_dashboard_collections
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
  end

  def load_receivable_relationship_indexes
    @anticipations_by_receivable = @anticipation_requests.group_by(&:receivable_id)
    @settlements_by_receivable = load_settlements_by_receivable
    @documents_by_receivable = load_documents_by_receivable
    @events_by_receivable = load_events_by_receivable
    @challenges_by_anticipation = load_challenges_by_anticipation
  end

  def build_dashboard_overview
    @stage_rows = @receivables.map { |receivable| stage_row_for(receivable) }
    @stage_completion = build_stage_completion(@stage_rows)
    @headline_cards = build_headline_cards
  end

  def build_selected_receivable_timeline
    @selected_receivable = select_receivable
    @timeline_entries = @selected_receivable ? timeline_entries_for(@selected_receivable) : []
  end

  def load_fdic_data
    return assign_empty_fdic_data unless fdic_persona?

    @fdic_anticipation_rows = build_fdic_anticipation_rows
    @daily_statistics = load_daily_statistics
  end

  def assign_empty_fdic_data
    @fdic_anticipation_rows = []
    @daily_statistics = []
  end

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
    return :hospital if hospital_actor_party?

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
      managed_hospital_ids = managed_hospital_party_ids
      return base.none if managed_hospital_ids.empty?

      base.where(debtor_party_id: managed_hospital_ids)
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
    anticipation_requests = anticipation_requests_for(receivable)
    receivable_events = receivable_events_for(receivable)
    documents = documents_for(receivable)
    settlements = settlements_for(receivable)

    stage_state = stage_state_for(
      receivable: receivable,
      anticipation_requests: anticipation_requests,
      receivable_events: receivable_events,
      documents: documents,
      settlements: settlements
    )
    last_update_at = latest_receivable_update_for(
      receivable: receivable,
      anticipation_requests: anticipation_requests,
      receivable_events: receivable_events,
      documents: documents,
      settlements: settlements
    )

    {
      receivable: receivable,
      stages: stage_state,
      completed_count: stage_state.values.count(true),
      last_update_at: last_update_at
    }
  end

  def anticipation_requests_for(receivable)
    @anticipations_by_receivable.fetch(receivable.id, [])
  end

  def receivable_events_for(receivable)
    @events_by_receivable.fetch(receivable.id, [])
  end

  def documents_for(receivable)
    @documents_by_receivable.fetch(receivable.id, [])
  end

  def settlements_for(receivable)
    @settlements_by_receivable.fetch(receivable.id, [])
  end

  def stage_state_for(receivable:, anticipation_requests:, receivable_events:, documents:, settlements:)
    {
      performed: true,
      requested: anticipation_requests.any?,
      challenge_issued: challenge_issued?(anticipation_requests:, receivable_events:),
      signed: documents.any? { |document| document.status == "SIGNED" },
      funded: receivable.status.in?(%w[FUNDED SETTLED]) || anticipation_requests.any? { |entry| entry.status.in?(%w[APPROVED FUNDED SETTLED]) },
      settled: receivable.status == "SETTLED" || settlements.any?
    }
  end

  def challenge_issued?(anticipation_requests:, receivable_events:)
    has_challenges = anticipation_requests.any? { |entry| @challenges_by_anticipation.fetch(entry.id, []).any? }
    has_challenges || receivable_events.any? { |event| event.event_type == "ANTICIPATION_CONFIRMATION_CHALLENGES_ISSUED" }
  end

  def latest_receivable_update_for(receivable:, anticipation_requests:, receivable_events:, documents:, settlements:)
    [
      receivable.updated_at,
      receivable_events.last&.occurred_at,
      documents.last&.signed_at,
      settlements.last&.paid_at,
      anticipation_requests.last&.updated_at
    ].compact.max
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
    receivable_entries.concat(build_receivable_event_entries(receivable))
    receivable_entries.concat(build_receivable_document_entries(receivable))
    receivable_entries.concat(build_receivable_settlement_entries(receivable))
    receivable_entries.concat(build_receivable_anticipation_entries(receivable))
    receivable_entries.sort_by { |entry| entry[:happened_at] || Time.at(0) }
  end

  def build_receivable_event_entries(receivable)
    receivable_events_for(receivable).map do |event|
      {
        happened_at: event.occurred_at,
        category: "Evento",
        title: EVENT_LABELS.fetch(event.event_type, event.event_type.humanize),
        details: "Sequência #{event.sequence} · #{event.actor_role.presence || "sistema"}",
        payload: event.payload
      }
    end
  end

  def build_receivable_document_entries(receivable)
    documents_for(receivable).flat_map do |document|
      [ timeline_signed_document_entry(document), *timeline_document_event_entries(document) ]
    end
  end

  def timeline_signed_document_entry(document)
    {
      happened_at: document.signed_at,
      category: "Documento",
      title: "Documento assinado (#{document.document_type})",
      details: "Método: #{document.signature_method}",
      payload: document.metadata
    }
  end

  def timeline_document_event_entries(document)
    document.document_events.map do |event|
      {
        happened_at: event.occurred_at,
        category: "Documento",
        title: event.event_type.humanize,
        details: "Evento documental",
        payload: event.payload
      }
    end
  end

  def build_receivable_settlement_entries(receivable)
    settlements_for(receivable).map do |settlement|
      {
        happened_at: settlement.paid_at,
        category: "Liquidação",
        title: "Pagamento liquidado",
        details: "Valor pago #{format_brl_for_timeline(settlement.paid_amount)}",
        payload: settlement.metadata
      }
    end
  end

  def build_receivable_anticipation_entries(receivable)
    anticipation_requests_for(receivable).map do |anticipation|
      challenge_count = @challenges_by_anticipation.fetch(anticipation.id, []).size
      {
        happened_at: anticipation.requested_at,
        category: "Antecipação",
        title: "Solicitação de antecipação",
        details: "Status #{human_status(anticipation.status)} · #{challenge_count} desafio(s) de confirmação",
        payload: anticipation.metadata
      }
    end
  end

  def build_headline_cards
    totals = headline_totals

    case @persona
    when :fdic
      [
        { label: "Carteira performada", value: totals[:gross], kind: :money, footnote: "#{@receivables.size} recebíveis no escopo" },
        { label: "Volume antecipado", value: totals[:requested], kind: :money, footnote: "#{@anticipation_requests.size} solicitações" },
        { label: "Retorno em desconto", value: totals[:discount], kind: :money, footnote: "Spread acumulado" },
        { label: "Efetivação das antecipações", value: totals[:settled_ratio], kind: :percentage, footnote: "#{totals[:settled_requests]} liquidadas" }
      ]
    when :hospital
      pending_count = @receivables.count { |entry| entry.status.in?(%w[PERFORMED ANTICIPATION_REQUESTED]) }
      [
        { label: "Recebíveis do hospital", value: totals[:gross], kind: :money, footnote: "#{@receivables.size} recebíveis" },
        { label: "Antecipações em andamento", value: pending_count, kind: :integer, footnote: "Fluxos ainda abertos" },
        { label: "Valor líquido contratado", value: totals[:net], kind: :money, footnote: "Após desconto e encargos" },
        { label: "Pagamentos liquidados", value: totals[:settled], kind: :money, footnote: "Repasse confirmado" }
      ]
    when :supplier, :physician
      in_progress = @anticipation_requests.count { |entry| entry.status.in?(%w[REQUESTED APPROVED FUNDED]) }
      [
        { label: "Minha carteira elegível", value: totals[:gross], kind: :money, footnote: "#{@receivables.size} recebíveis vinculados" },
        { label: "Solicitado para antecipação", value: totals[:requested], kind: :money, footnote: "#{@anticipation_requests.size} solicitações" },
        { label: "Valor líquido esperado", value: totals[:net], kind: :money, footnote: "Projeção líquida" },
        { label: "Solicitações em andamento", value: in_progress, kind: :integer, footnote: "Aguardando etapa seguinte" }
      ]
    else
      [
        { label: "Carteira acompanhada", value: totals[:gross], kind: :money, footnote: "#{@receivables.size} recebíveis" },
        { label: "Antecipações", value: totals[:requested], kind: :money, footnote: "#{@anticipation_requests.size} solicitações" },
        { label: "Desconto acumulado", value: totals[:discount], kind: :money, footnote: "Resultado financeiro" },
        { label: "Liquidação", value: totals[:settled], kind: :money, footnote: "Pagamentos concluídos" }
      ]
    end
  end

  def headline_totals
    settled_requests = @anticipation_requests.count { |entry| entry.status == "SETTLED" }
    {
      gross: @receivables.sum { |entry| entry.gross_amount.to_d },
      requested: @anticipation_requests.sum { |entry| entry.requested_amount.to_d },
      discount: @anticipation_requests.sum { |entry| entry.discount_amount.to_d },
      net: @anticipation_requests.sum { |entry| entry.net_amount.to_d },
      settled: @settlements_by_receivable.values.flatten.sum { |entry| entry.paid_amount.to_d },
      settled_requests: settled_requests,
      settled_ratio: settled_ratio(settled_requests)
    }
  end

  def settled_ratio(settled_requests)
    return BigDecimal("0") if @anticipation_requests.empty?

    BigDecimal(settled_requests.to_s) / BigDecimal(@anticipation_requests.size.to_s)
  end

  def build_fdic_anticipation_rows
    calculator = Fdic::ExposureCalculator.new(valuation_time: Time.current)

    @anticipation_requests.map do |anticipation|
      receivable = anticipation.receivable
      exposure_metrics = calculator.call(anticipation_request: anticipation, due_at: receivable&.due_at)
      provenance = receivable_provenance_payload(receivable)

      {
        anticipation: anticipation,
        receivable: receivable,
        requester: anticipation.requester_party,
        source_hospital_name: provenance&.dig(:hospital, :legal_name),
        source_organization_name: provenance&.dig(:owning_organization, :legal_name),
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

  def managed_hospital_party_ids
    return [] if current_party_id.blank?

    own_hospital_party_ids = Party.where(
      tenant_id: current_tenant_id,
      id: current_party_id,
      kind: "HOSPITAL"
    ).pluck(:id)
    owned_hospital_party_ids = HospitalOwnership.where(
      tenant_id: current_tenant_id,
      organization_party_id: current_party_id,
      active: true
    ).pluck(:hospital_party_id)

    (own_hospital_party_ids + owned_hospital_party_ids).uniq
  end

  def hospital_actor_party?
    return false if current_party_id.blank?
    return true if Party.where(tenant_id: current_tenant_id, id: current_party_id, kind: "HOSPITAL").exists?

    HospitalOwnership.where(
      tenant_id: current_tenant_id,
      organization_party_id: current_party_id,
      active: true
    ).exists?
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

  def format_brl_for_timeline(value)
    ApplicationController.helpers.format_brl(value)
  end
end
