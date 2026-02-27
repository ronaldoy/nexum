require "digest"

module Admin
  class AnticipationRiskRulesController < ApplicationController
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
      effective_from
      effective_until
    ].freeze
    UPDATE_PERMITTED_FIELDS = %i[
      tenant_id
      decision
      priority
      max_single_request_amount
      max_daily_requested_amount
      max_outstanding_exposure_amount
      max_open_requests_count
      effective_from
      effective_until
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
      return if Current.session&.admin_webauthn_verified_recently?

      redirect_to new_admin_passkey_verification_path(return_to: request.fullpath),
        alert: "Confirme a passkey para gerenciar regras de risco de antecipação."
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
      attrs = normalized_create_attributes

      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        rule = AnticipationRiskRule.create!(attrs)
        record_rule_event!(rule:, event_type: "RULE_CREATED", payload: { after: rule_snapshot(rule) })
        create_action_log!(
          action_type: "ANTICIPATION_RISK_RULE_CREATED",
          success: true,
          target_id: rule.id,
          metadata: { rule_id: rule.id, scope_type: rule.scope_type, decision: rule.decision }
        )
        rule
      end
    end

    def update_rule!
      attrs = normalized_update_attributes

      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        rule = AnticipationRiskRule.lock.find_by!(tenant_id: @selected_tenant.id, id: params[:id])
        before_snapshot = rule_snapshot(rule)
        rule.update!(attrs)

        record_rule_event!(
          rule: rule,
          event_type: "RULE_UPDATED",
          payload: {
            before: before_snapshot,
            after: rule_snapshot(rule)
          }
        )
        create_action_log!(
          action_type: "ANTICIPATION_RISK_RULE_UPDATED",
          success: true,
          target_id: rule.id,
          metadata: { rule_id: rule.id, decision: rule.decision }
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
        effective_from: parse_datetime(attrs[:effective_from], field: "início de vigência"),
        effective_until: parse_datetime(attrs[:effective_until], field: "fim de vigência")
      }
    end

    def normalized_update_attributes
      attrs = update_params

      {
        decision: normalize_decision(attrs.fetch(:decision)),
        priority: parse_priority(attrs[:priority]),
        max_single_request_amount: parse_money_limit(attrs[:max_single_request_amount], field: "limite máximo por solicitação"),
        max_daily_requested_amount: parse_money_limit(attrs[:max_daily_requested_amount], field: "limite diário solicitado"),
        max_outstanding_exposure_amount: parse_money_limit(attrs[:max_outstanding_exposure_amount], field: "limite de exposição em aberto"),
        max_open_requests_count: parse_positive_integer_limit(attrs[:max_open_requests_count], field: "limite de solicitações em aberto"),
        effective_from: parse_datetime(attrs[:effective_from], field: "início de vigência"),
        effective_until: parse_datetime(attrs[:effective_until], field: "fim de vigência")
      }
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

    def parse_datetime(raw_value, field:)
      value = raw_value.to_s.strip
      return nil if value.blank?

      parsed = Time.zone.parse(value)
      raise ValidationError, "#{field.capitalize} inválido." if parsed.blank?

      parsed
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
        actor_party_id: Current.user&.party_id,
        actor_role: Current.role,
        request_id: request.request_id,
        occurred_at: occurred_at,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: payload
      )
    end

    def create_action_log!(action_type:, success:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_id: @selected_tenant.id,
        actor_party_id: Current.user&.party_id,
        action_type: action_type,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        request_id: request.request_id,
        endpoint_path: request.fullpath,
        http_method: request.method,
        channel: "ADMIN",
        target_type: "AnticipationRiskRule",
        target_id: target_id,
        success: success,
        occurred_at: Time.current,
        metadata: normalized_metadata(metadata)
      )
    end

    def normalized_metadata(raw_metadata)
      case raw_metadata
      when ActionController::Parameters
        normalized_metadata(raw_metadata.to_unsafe_h)
      when Hash
        raw_metadata.each_with_object({}) do |(key, value), output|
          output[key.to_s] = normalized_metadata(value)
        end
      when Array
        raw_metadata.map { |value| normalized_metadata(value) }
      else
        raw_metadata
      end
    end

    def decimal_string(value)
      return nil if value.blank?

      format("%.2f", value.to_d)
    end

    def create_params
      params.require(:anticipation_risk_rule).permit(*CREATE_PERMITTED_FIELDS)
    end

    def update_params
      params.require(:anticipation_risk_rule).permit(*UPDATE_PERMITTED_FIELDS)
    end

    def with_tenant_database_context(tenant_id:)
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction(requires_new: true) do
          set_database_context!("app.tenant_id", tenant_id)
          set_database_context!("app.actor_id", Current.actor_id)
          set_database_context!("app.role", Current.role)
          yield
        end
      end
    end

    def set_database_context!(key, value)
      ActiveRecord::Base.connection.raw_connection.exec_params(
        "SELECT set_config($1, $2, true)",
        [ key.to_s, value.to_s ]
      )
    end
  end
end
