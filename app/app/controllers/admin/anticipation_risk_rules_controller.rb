require "digest"

module Admin
  class AnticipationRiskRulesController < ApplicationController
    include AdminTenantScopedContext
    include AdminPasskeyMode

    MAX_RULES = 300
    MAX_EVENTS = 200
    CREATE_PERMITTED_FIELDS = %i[
      tenant_id
      scope_type
      scope_party_id
      decision
      priority
      max_single_request_amount
      max_daily_requested_amount
      max_outstanding_exposure_amount
      max_open_requests_count
      max_requests_per_minute
      max_requests_per_hour
      pair_spike_multiplier
      pair_spike_min_daily_amount
      near_limit_attempts_window_minutes
      near_limit_attempts_max_count
      near_limit_ratio
      effective_from
      effective_until
      change_reason
    ].freeze
    UPDATE_PERMITTED_FIELDS = %i[
      tenant_id
      decision
      priority
      max_single_request_amount
      max_daily_requested_amount
      max_outstanding_exposure_amount
      max_open_requests_count
      max_requests_per_minute
      max_requests_per_hour
      pair_spike_multiplier
      pair_spike_min_daily_amount
      near_limit_attempts_window_minutes
      near_limit_attempts_max_count
      near_limit_ratio
      effective_from
      effective_until
      change_reason
    ].freeze

    class ValidationError < StandardError; end

    before_action :ensure_ops_admin!
    before_action :require_passkey_step_up!
    before_action :load_tenants!
    before_action :resolve_selected_tenant!
    before_action :load_scope_parties!
    before_action :prepare_form_options!

    def index
      load_rules_and_events!
    end

    def create
      with_validation_error_handling do
        create_rule!
        redirect_to admin_anticipation_risk_rules_path(tenant_id: @selected_tenant.id),
          notice: "Regra de risco criada com sucesso."
      end
    end

    def update
      with_validation_error_handling do
        update_rule!
        redirect_to admin_anticipation_risk_rules_path(tenant_id: @selected_tenant.id),
          notice: "Regra de risco atualizada com sucesso."
      end
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_anticipation_risk_rules_path(tenant_id: @selected_tenant.id),
        alert: "Regra de risco não encontrada para o tenant selecionado."
    end

    def activate
      change_rule_status!(active: true, success_notice: "Regra ativada com sucesso.", event_type: "RULE_ACTIVATED")
    end

    def deactivate
      change_rule_status!(active: false, success_notice: "Regra desativada com sucesso.", event_type: "RULE_DEACTIVATED")
    end

    private

    def ensure_ops_admin!
      return if Current.user&.role == "ops_admin"

      redirect_to root_path, alert: "Acesso restrito ao perfil de operação."
    end

    def require_passkey_step_up!
      require_admin_passkey_step_up!(alert: "Confirme a passkey para gerenciar regras de risco de antecipação.")
    end

    def load_tenants!
      @tenants = Tenant.order(:slug).select(:id, :slug, :name, :active).to_a
    end

    def resolve_selected_tenant!
      requested_tenant_id = params[:tenant_id].presence ||
        params.dig(:anticipation_risk_rule, :tenant_id).presence ||
        Current.user&.tenant_id

      @selected_tenant = @tenants.find { |tenant| tenant.id.to_s == requested_tenant_id.to_s }
      raise ActiveRecord::RecordNotFound if @selected_tenant.blank?
    end

    def load_scope_parties!
      @scope_parties = with_tenant_database_context(tenant_id: @selected_tenant.id) do
        Party
          .where(tenant_id: @selected_tenant.id, active: true)
          .order(:kind, :legal_name)
          .select(:id, :kind, :legal_name, :document_number, :document_type)
          .to_a
      end
    end

    def prepare_form_options!
      @scope_type_options = [
        [ "Padrão do tenant", "TENANT_DEFAULT" ],
        [ "Médico (party)", "PHYSICIAN_PARTY" ],
        [ "CNPJ (party)", "CNPJ_PARTY" ],
        [ "Hospital (party)", "HOSPITAL_PARTY" ]
      ]
      @decision_options = [
        [ "Bloquear", "BLOCK" ],
        [ "Revisão manual", "REVIEW" ],
        [ "Permitir", "ALLOW" ]
      ]
    end

    def load_rules_and_events!
      @risk_rules = with_tenant_database_context(tenant_id: @selected_tenant.id) do
        AnticipationRiskRule
          .where(tenant_id: @selected_tenant.id)
          .includes(:scope_party)
          .order(active: :desc, priority: :asc, created_at: :desc)
          .limit(MAX_RULES)
          .to_a
      end

      @risk_rule_events = with_tenant_database_context(tenant_id: @selected_tenant.id) do
        AnticipationRiskRuleEvent
          .where(tenant_id: @selected_tenant.id)
          .includes(:anticipation_risk_rule, :actor_party)
          .order(created_at: :desc)
          .limit(MAX_EVENTS)
          .to_a
      end
    end

    def create_rule!
      attrs, change_reason = normalized_create_attributes

      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        conflicting_rule_ids = conflicting_rule_ids_for(candidate_attrs: attrs)
        ensure_conflict_justification!(conflicting_rule_ids: conflicting_rule_ids, change_reason: change_reason)

        rule = AnticipationRiskRule.create!(attrs)
        record_rule_event!(
          rule:,
          event_type: "RULE_CREATED",
          payload: {
            after: rule_snapshot(rule),
            change_reason: change_reason,
            conflicting_rule_ids: conflicting_rule_ids
          }.compact
        )
        create_action_log!(
          action_type: "ANTICIPATION_RISK_RULE_CREATED",
          success: true,
          target_id: rule.id,
          metadata: {
            rule_id: rule.id,
            scope_type: rule.scope_type,
            decision: rule.decision,
            change_reason: change_reason,
            conflicting_rule_ids: conflicting_rule_ids
          }.compact
        )
        rule
      end
    end

    def update_rule!
      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        rule = AnticipationRiskRule.lock.find_by!(tenant_id: @selected_tenant.id, id: params[:id])
        attrs, change_reason = normalized_update_attributes
        candidate_attrs = build_candidate_attrs(rule:, attrs:)
        conflicting_rule_ids = conflicting_rule_ids_for(candidate_attrs:, excluding_rule_id: rule.id)
        ensure_conflict_justification!(conflicting_rule_ids: conflicting_rule_ids, change_reason: change_reason)
        before_snapshot = rule_snapshot(rule)
        rule.update!(attrs)

        record_rule_event!(
          rule: rule,
          event_type: "RULE_UPDATED",
          payload: {
            before: before_snapshot,
            after: rule_snapshot(rule),
            change_reason: change_reason,
            conflicting_rule_ids: conflicting_rule_ids
          }
        )
        create_action_log!(
          action_type: "ANTICIPATION_RISK_RULE_UPDATED",
          success: true,
          target_id: rule.id,
          metadata: {
            rule_id: rule.id,
            decision: rule.decision,
            change_reason: change_reason,
            conflicting_rule_ids: conflicting_rule_ids
          }.compact
        )
        rule
      end
    end

    def change_rule_status!(active:, success_notice:, event_type:)
      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        rule = AnticipationRiskRule.lock.find_by!(tenant_id: @selected_tenant.id, id: params[:id])
        if rule.active != active
          before_snapshot = rule_snapshot(rule)
          rule.update!(active: active)

          record_rule_event!(
            rule: rule,
            event_type: event_type,
            payload: {
              before: before_snapshot,
              after: rule_snapshot(rule)
            }
          )
          create_action_log!(
            action_type: active ? "ANTICIPATION_RISK_RULE_ACTIVATED" : "ANTICIPATION_RISK_RULE_DEACTIVATED",
            success: true,
            target_id: rule.id,
            metadata: { rule_id: rule.id, active: rule.active }
          )
        end
      end

      redirect_to admin_anticipation_risk_rules_path(tenant_id: @selected_tenant.id), notice: success_notice
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_anticipation_risk_rules_path(tenant_id: @selected_tenant.id),
        alert: "Regra de risco não encontrada para o tenant selecionado."
    rescue ValidationError => error
      load_rules_and_events!
      flash.now[:alert] = error.message
      render :index, status: :unprocessable_entity
    rescue ActiveRecord::RecordInvalid => error
      load_rules_and_events!
      flash.now[:alert] = error.record.errors.full_messages.to_sentence
      render :index, status: :unprocessable_entity
    end

    def with_validation_error_handling
      yield
    rescue ValidationError => error
      load_rules_and_events!
      flash.now[:alert] = error.message
      render :index, status: :unprocessable_entity
    rescue ActiveRecord::RecordInvalid => error
      load_rules_and_events!
      flash.now[:alert] = error.record.errors.full_messages.to_sentence
      render :index, status: :unprocessable_entity
    end

    def normalized_create_attributes
      attrs = create_params
      scope_type = normalize_scope_type(attrs.fetch(:scope_type))

      [
        {
        tenant_id: @selected_tenant.id,
        scope_type: scope_type,
        scope_party_id: resolve_scope_party_id(scope_type: scope_type, raw_scope_party_id: attrs[:scope_party_id]),
        decision: normalize_decision(attrs.fetch(:decision)),
        priority: parse_priority(attrs[:priority]),
        max_single_request_amount: parse_money_limit(attrs[:max_single_request_amount], field: "limite máximo por solicitação"),
        max_daily_requested_amount: parse_money_limit(attrs[:max_daily_requested_amount], field: "limite diário solicitado"),
        max_outstanding_exposure_amount: parse_money_limit(attrs[:max_outstanding_exposure_amount], field: "limite de exposição em aberto"),
        max_open_requests_count: parse_positive_integer_limit(attrs[:max_open_requests_count], field: "limite de solicitações em aberto"),
        max_requests_per_minute: parse_positive_integer_limit(attrs[:max_requests_per_minute], field: "limite de requisições por minuto"),
        max_requests_per_hour: parse_positive_integer_limit(attrs[:max_requests_per_hour], field: "limite de requisições por hora"),
        pair_spike_multiplier: parse_multiplier(attrs[:pair_spike_multiplier], field: "multiplicador de pico por par"),
        pair_spike_min_daily_amount: parse_money_limit(attrs[:pair_spike_min_daily_amount], field: "limiar mínimo diário de pico"),
        near_limit_attempts_window_minutes: parse_positive_integer_limit(attrs[:near_limit_attempts_window_minutes], field: "janela de tentativas próximas ao limite"),
        near_limit_attempts_max_count: parse_positive_integer_limit(attrs[:near_limit_attempts_max_count], field: "máximo de tentativas próximas ao limite"),
        near_limit_ratio: parse_ratio(attrs[:near_limit_ratio], field: "razão para tentativas próximas ao limite"),
        effective_from: parse_datetime(attrs[:effective_from], field: "início de vigência"),
        effective_until: parse_datetime(attrs[:effective_until], field: "fim de vigência")
      },
        normalize_change_reason(attrs[:change_reason])
      ]
    end

    def normalized_update_attributes
      attrs = update_params

      [
        {
        decision: normalize_decision(attrs.fetch(:decision)),
        priority: parse_priority(attrs[:priority]),
        max_single_request_amount: parse_money_limit(attrs[:max_single_request_amount], field: "limite máximo por solicitação"),
        max_daily_requested_amount: parse_money_limit(attrs[:max_daily_requested_amount], field: "limite diário solicitado"),
        max_outstanding_exposure_amount: parse_money_limit(attrs[:max_outstanding_exposure_amount], field: "limite de exposição em aberto"),
        max_open_requests_count: parse_positive_integer_limit(attrs[:max_open_requests_count], field: "limite de solicitações em aberto"),
        max_requests_per_minute: parse_positive_integer_limit(attrs[:max_requests_per_minute], field: "limite de requisições por minuto"),
        max_requests_per_hour: parse_positive_integer_limit(attrs[:max_requests_per_hour], field: "limite de requisições por hora"),
        pair_spike_multiplier: parse_multiplier(attrs[:pair_spike_multiplier], field: "multiplicador de pico por par"),
        pair_spike_min_daily_amount: parse_money_limit(attrs[:pair_spike_min_daily_amount], field: "limiar mínimo diário de pico"),
        near_limit_attempts_window_minutes: parse_positive_integer_limit(attrs[:near_limit_attempts_window_minutes], field: "janela de tentativas próximas ao limite"),
        near_limit_attempts_max_count: parse_positive_integer_limit(attrs[:near_limit_attempts_max_count], field: "máximo de tentativas próximas ao limite"),
        near_limit_ratio: parse_ratio(attrs[:near_limit_ratio], field: "razão para tentativas próximas ao limite"),
        effective_from: parse_datetime(attrs[:effective_from], field: "início de vigência"),
        effective_until: parse_datetime(attrs[:effective_until], field: "fim de vigência")
      },
        normalize_change_reason(attrs[:change_reason])
      ]
    end

    def normalize_scope_type(raw_scope_type)
      scope_type = raw_scope_type.to_s.strip.upcase
      return scope_type if AnticipationRiskRule::SCOPE_TYPES.include?(scope_type)

      raise ValidationError, "Tipo de escopo inválido."
    end

    def normalize_decision(raw_decision)
      decision = raw_decision.to_s.strip.upcase
      return decision if AnticipationRiskRule::DECISIONS.include?(decision)

      raise ValidationError, "Ação da regra inválida."
    end

    def resolve_scope_party_id(scope_type:, raw_scope_party_id:)
      return nil if scope_type == "TENANT_DEFAULT"

      scope_party_id = raw_scope_party_id.to_s.strip
      raise ValidationError, "Selecione a parte para o escopo informado." if scope_party_id.blank?

      scope_party = @scope_parties.find { |party| party.id.to_s == scope_party_id }
      raise ValidationError, "Parte informada não encontrada no tenant selecionado." if scope_party.blank?

      scope_party.id
    end

    def parse_priority(raw_priority)
      return 100 if raw_priority.to_s.strip.blank?

      value = Integer(raw_priority, exception: false)
      if value.blank? || value <= 0
        raise ValidationError, "Prioridade deve ser um inteiro positivo."
      end

      value
    end

    def parse_money_limit(raw_value, field:)
      value = raw_value.to_s.strip
      return nil if value.blank?

      parsed = BigDecimal(value)
      raise ValidationError, "#{field.capitalize} deve ser maior que zero." unless parsed.positive?

      FinancialRounding.money(parsed)
    rescue ArgumentError
      raise ValidationError, "#{field.capitalize} é inválido."
    end

    def parse_positive_integer_limit(raw_value, field:)
      value = raw_value.to_s.strip
      return nil if value.blank?

      parsed = Integer(value, exception: false)
      if parsed.blank? || parsed <= 0
        raise ValidationError, "#{field.capitalize} deve ser um inteiro positivo."
      end

      parsed
    end

    def parse_multiplier(raw_value, field:)
      value = raw_value.to_s.strip
      return nil if value.blank?

      parsed = BigDecimal(value)
      raise ValidationError, "#{field.capitalize} deve ser maior que um." unless parsed > 1

      parsed.round(4, BigDecimal::ROUND_UP)
    rescue ArgumentError
      raise ValidationError, "#{field.capitalize} é inválido."
    end

    def parse_ratio(raw_value, field:)
      value = raw_value.to_s.strip
      return nil if value.blank?

      parsed = BigDecimal(value)
      if parsed <= 0 || parsed > 1
        raise ValidationError, "#{field.capitalize} deve estar entre 0 e 1."
      end

      parsed.round(6, BigDecimal::ROUND_UP)
    rescue ArgumentError
      raise ValidationError, "#{field.capitalize} é inválido."
    end

    def parse_datetime(raw_value, field:)
      value = raw_value.to_s.strip
      return nil if value.blank?

      parsed = Time.zone.parse(value)
      raise ValidationError, "#{field.capitalize} inválido." if parsed.blank?

      parsed
    end

    def normalize_change_reason(raw_value)
      value = raw_value.to_s.strip
      return nil if value.blank?

      value
    end

    def rule_snapshot(rule)
      {
        id: rule.id,
        scope_type: rule.scope_type,
        scope_party_id: rule.scope_party_id,
        decision: rule.decision,
        active: rule.active,
        priority: rule.priority,
        max_single_request_amount: decimal_string(rule.max_single_request_amount),
        max_daily_requested_amount: decimal_string(rule.max_daily_requested_amount),
        max_outstanding_exposure_amount: decimal_string(rule.max_outstanding_exposure_amount),
        max_open_requests_count: rule.max_open_requests_count,
        max_requests_per_minute: rule.max_requests_per_minute,
        max_requests_per_hour: rule.max_requests_per_hour,
        pair_spike_multiplier: decimal_ratio_string(rule.pair_spike_multiplier),
        pair_spike_min_daily_amount: decimal_string(rule.pair_spike_min_daily_amount),
        near_limit_attempts_window_minutes: rule.near_limit_attempts_window_minutes,
        near_limit_attempts_max_count: rule.near_limit_attempts_max_count,
        near_limit_ratio: decimal_ratio_string(rule.near_limit_ratio),
        effective_from: rule.effective_from&.utc&.iso8601(6),
        effective_until: rule.effective_until&.utc&.iso8601(6)
      }.compact
    end

    def record_rule_event!(rule:, event_type:, payload:)
      occurred_at = Time.current
      previous = rule.anticipation_risk_rule_events
        .order(sequence: :desc)
        .limit(1)
        .pluck(:sequence, :event_hash)
        .first

      sequence = previous ? previous.fetch(0) + 1 : 1
      prev_hash = previous&.fetch(1)
      event_hash = Digest::SHA256.hexdigest(
        CanonicalJson.encode(
          anticipation_risk_rule_id: rule.id,
          sequence: sequence,
          event_type: event_type,
          occurred_at: occurred_at.utc.iso8601(6),
          request_id: request.request_id,
          prev_hash: prev_hash,
          payload: payload
        )
      )

      AnticipationRiskRuleEvent.create!(
        tenant_id: @selected_tenant.id,
        anticipation_risk_rule: rule,
        sequence: sequence,
        event_type: event_type,
        actor_party_id: tenant_scoped_audit_actor_party_id(@selected_tenant.id),
        actor_role: Current.role,
        request_id: request.request_id,
        occurred_at: occurred_at,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: normalized_metadata(payload).merge(
          "admin_user_uuid_id" => Current.user&.uuid_id
        ).compact
      )
    end

    def create_action_log!(action_type:, success:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_scoped_audit_context(tenant_id: @selected_tenant.id, metadata: metadata).merge(
          action_type: action_type,
          target_type: "AnticipationRiskRule",
          target_id: target_id,
          success: success,
          occurred_at: Time.current
        )
      )
    end

    def decimal_string(value)
      return nil if value.blank?

      format("%.2f", value.to_d)
    end

    def decimal_ratio_string(value)
      return nil if value.blank?

      value.to_d.to_s("F")
    end

    def build_candidate_attrs(rule:, attrs:)
      {
        scope_type: rule.scope_type,
        scope_party_id: rule.scope_party_id,
        decision: attrs[:decision],
        active: rule.active,
        effective_from: attrs[:effective_from],
        effective_until: attrs[:effective_until]
      }
    end

    def conflicting_rule_ids_for(candidate_attrs:, excluding_rule_id: nil)
      return [] unless candidate_attrs.fetch(:active, true)

      relation = AnticipationRiskRule.where(tenant_id: @selected_tenant.id, active: true)
      relation = relation.where.not(id: excluding_rule_id) if excluding_rule_id.present?
      relation = relation.where.not(decision: candidate_attrs[:decision])

      relation.to_a.select do |existing_rule|
        scopes_overlap?(candidate_attrs: candidate_attrs, existing_rule: existing_rule) &&
          effective_windows_overlap?(
            candidate_from: candidate_attrs[:effective_from],
            candidate_until: candidate_attrs[:effective_until],
            existing_from: existing_rule.effective_from,
            existing_until: existing_rule.effective_until
          )
      end.map(&:id)
    end

    def scopes_overlap?(candidate_attrs:, existing_rule:)
      candidate_scope_type = candidate_attrs[:scope_type]
      candidate_scope_party_id = candidate_attrs[:scope_party_id]

      return true if candidate_scope_type == "TENANT_DEFAULT" || existing_rule.scope_type == "TENANT_DEFAULT"
      return false unless candidate_scope_type == existing_rule.scope_type

      if candidate_scope_type == "CNPJ_PARTY"
        candidate_document = scope_party_document_number(candidate_scope_party_id)
        existing_document = scope_party_document_number(existing_rule.scope_party_id)
        return candidate_scope_party_id.to_s == existing_rule.scope_party_id.to_s if candidate_document.blank? || existing_document.blank?

        return candidate_document == existing_document
      end

      candidate_scope_party_id.to_s == existing_rule.scope_party_id.to_s
    end

    def effective_windows_overlap?(candidate_from:, candidate_until:, existing_from:, existing_until:)
      candidate_start = candidate_from || Time.utc(1970, 1, 1)
      candidate_end = candidate_until || Time.utc(9999, 12, 31)
      existing_start = existing_from || Time.utc(1970, 1, 1)
      existing_end = existing_until || Time.utc(9999, 12, 31)

      candidate_start <= existing_end && existing_start <= candidate_end
    end

    def scope_party_document_number(scope_party_id)
      return nil if scope_party_id.blank?

      @scope_party_documents ||= {}
      @scope_party_documents[scope_party_id] ||= Party.where(tenant_id: @selected_tenant.id).where(id: scope_party_id).pick(:document_number)
    end

    def ensure_conflict_justification!(conflicting_rule_ids:, change_reason:)
      return if conflicting_rule_ids.empty?
      return if change_reason.present?

      raise ValidationError, "Existe conflito com regras ativas de ação divergente. Informe justificativa da mudança."
    end

    def create_params
      params.require(:anticipation_risk_rule).permit(*CREATE_PERMITTED_FIELDS)
    end

    def update_params
      params.require(:anticipation_risk_rule).permit(*UPDATE_PERMITTED_FIELDS)
    end

  end
end
