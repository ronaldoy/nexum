require "digest"
require "json"

module Admin
  class AnticipationReviewsController < ApplicationController
    include AdminTenantScopedContext
    include AdminPasskeyMode

    MAX_PENDING_REVIEWS = 300
    MAX_REVIEW_NOTE_LENGTH = 1000

    class ValidationError < StandardError; end

    before_action :ensure_ops_admin!
    before_action :require_passkey_step_up!
    before_action :load_tenants!
    before_action :resolve_selected_tenant!

    def index
      load_pending_reviews!
    end

    def approve
      with_validation_error_handling do
        process_review_decision!(approved: true)
        redirect_to admin_anticipation_reviews_path(tenant_id: @selected_tenant.id),
          notice: "Solicitação aprovada para seguir no fluxo de confirmação."
      end
    end

    def reject
      with_validation_error_handling do
        process_review_decision!(approved: false)
        redirect_to admin_anticipation_reviews_path(tenant_id: @selected_tenant.id),
          notice: "Solicitação rejeitada com sucesso."
      end
    end

    private

    def ensure_ops_admin!
      return if Current.user&.role == "ops_admin"

      redirect_to root_path, alert: "Acesso restrito ao perfil de operação."
    end

    def require_passkey_step_up!
      require_admin_passkey_step_up!(alert: "Confirme a passkey para gerenciar revisões manuais de antecipação.")
    end

    def load_tenants!
      @tenants = Tenant.order(:slug).select(:id, :slug, :name, :active).to_a
    end

    def resolve_selected_tenant!
      requested_tenant_id = params[:tenant_id].presence || Current.user&.tenant_id
      @selected_tenant = @tenants.find { |tenant| tenant.id.to_s == requested_tenant_id.to_s }
      raise ActiveRecord::RecordNotFound if @selected_tenant.blank?
    end

    def load_pending_reviews!
      @pending_reviews = with_tenant_database_context(tenant_id: @selected_tenant.id) do
        AnticipationRequest
          .where(tenant_id: @selected_tenant.id, status: "PENDING_REVIEW")
          .includes(:receivable, :requester_party)
          .order(requested_at: :asc, created_at: :asc)
          .limit(MAX_PENDING_REVIEWS)
          .to_a
      end

      request_ids = @pending_reviews.map(&:id)
      @latest_risk_decisions_by_request_id = with_tenant_database_context(tenant_id: @selected_tenant.id) do
        AnticipationRiskDecision
          .where(tenant_id: @selected_tenant.id, anticipation_request_id: request_ids)
          .order(evaluated_at: :desc)
          .to_a
          .group_by(&:anticipation_request_id)
          .transform_values(&:first)
      end
    end

    def process_review_decision!(approved:)
      note = parse_review_note!(raw_note: params[:review_note], require_note: !approved)
      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        anticipation_request = AnticipationRequest.lock.find_by!(tenant_id: @selected_tenant.id, id: params[:id])
        unless anticipation_request.status == "PENDING_REVIEW"
          raise ValidationError, "A solicitação não está mais pendente de revisão."
        end

        decision = approved ? "APPROVED" : "REJECTED"
        target_status = approved ? "REQUESTED" : "REJECTED"
        reviewed_at = Time.current
        reviewer_party_id = tenant_scoped_audit_actor_party_id(@selected_tenant.id)
        transition_metadata = {
          "review_decision" => decision,
          "review_decision_at" => reviewed_at.utc.iso8601(6),
          "review_decision_by_party_id" => reviewer_party_id,
          "review_decision_by_admin_user_uuid_id" => Current.user&.uuid_id,
          "review_note" => note,
          "review_decision_request_id" => request.request_id
        }.compact

        anticipation_request.transition_status!(
          target_status,
          metadata: transition_metadata
        )

        create_receivable_event!(
          anticipation_request: anticipation_request,
          event_type: approved ? "ANTICIPATION_REVIEW_APPROVED" : "ANTICIPATION_REVIEW_REJECTED",
          decision: decision,
          note: note,
          reviewed_at: reviewed_at,
          reviewed_by_party_id: reviewer_party_id
        )
        create_action_log!(
          action_type: approved ? "ANTICIPATION_REVIEW_APPROVED" : "ANTICIPATION_REVIEW_REJECTED",
          requester_party_id: anticipation_request.requester_party_id,
          target_id: anticipation_request.id,
          metadata: {
            review_decision: decision,
            review_decision_request_id: request.request_id,
            review_note: note
          }.compact
        )
      end
    end

    def parse_review_note!(raw_note:, require_note:)
      note = raw_note.to_s.strip
      if require_note && note.blank?
        raise ValidationError, "Informe o motivo da rejeição."
      end
      if note.length > MAX_REVIEW_NOTE_LENGTH
        raise ValidationError, "A nota da revisão deve ter no máximo #{MAX_REVIEW_NOTE_LENGTH} caracteres."
      end

      return nil if note.blank?

      note
    end

    def create_receivable_event!(anticipation_request:, event_type:, decision:, note:, reviewed_at:, reviewed_by_party_id:)
      receivable = anticipation_request.receivable
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous[0] + 1 : 1
      prev_hash = previous&.[](1)

      payload = {
        anticipation_request_id: anticipation_request.id,
        status: anticipation_request.status,
        review_decision: decision,
        review_note: note,
        reviewed_at: reviewed_at.utc.iso8601(6),
        reviewed_by_party_id: reviewed_by_party_id,
        reviewed_by_admin_user_uuid_id: Current.user&.uuid_id,
        request_id: request.request_id
      }.compact

      event_hash = Digest::SHA256.hexdigest(
        canonical_json(
          {
            receivable_id: receivable.id,
            sequence: sequence,
            event_type: event_type,
            payload: payload,
            occurred_at: reviewed_at.utc.iso8601(6),
            prev_hash: prev_hash
          }
        )
      )

      ReceivableEvent.create!(
        tenant_id: @selected_tenant.id,
        receivable: receivable,
        actor_party_id: reviewed_by_party_id,
        event_type: event_type,
        payload: payload,
        sequence: sequence,
        prev_hash: prev_hash,
        event_hash: event_hash,
        occurred_at: reviewed_at
      )
    end

    def create_action_log!(action_type:, requester_party_id:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_scoped_audit_context(
          tenant_id: @selected_tenant.id,
          metadata: metadata.merge("requester_party_id" => requester_party_id)
        ).merge(
          action_type: action_type,
          target_type: "AnticipationRequest",
          target_id: target_id,
          success: true,
          occurred_at: Time.current
        )
      )
    end

    def canonical_json(value)
      case value
      when Hash
        entries = value.keys.map(&:to_s).sort.map do |key|
          "#{JSON.generate(key)}:#{canonical_json(value[key] || value[key.to_sym])}"
        end
        "{#{entries.join(",")}}"
      when Array
        "[#{value.map { |entry| canonical_json(entry) }.join(",")}]"
      else
        JSON.generate(value)
      end
    end

    def with_validation_error_handling
      yield
    rescue ValidationError => error
      load_pending_reviews!
      flash.now[:alert] = error.message
      render :index, status: :unprocessable_entity
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_anticipation_reviews_path(tenant_id: @selected_tenant.id),
        alert: "Solicitação não encontrada para o tenant selecionado."
    end

  end
end
