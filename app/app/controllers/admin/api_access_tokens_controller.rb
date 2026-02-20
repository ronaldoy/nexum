module Admin
  class ApiAccessTokensController < ApplicationController
    MAX_TOKENS = 200

    class ValidationError < StandardError; end

    before_action :ensure_ops_admin!
    before_action :require_passkey_step_up!
    before_action :load_tenants!
    before_action :resolve_selected_tenant!

    def index
      @tokens = list_tokens_for_selected_tenant
    end

    def create
      issued = issue_token!

      respond_to do |format|
        format.html do
          flash[:notice] = "Token de integração emitido com sucesso."
          flash[:issued_api_access_token] = issued.fetch(:raw_token)
          redirect_to admin_api_access_tokens_path(tenant_id: @selected_tenant.id)
        end

        format.json do
          render json: {
            data: serialize_token(issued.fetch(:token)).merge(raw_token: issued.fetch(:raw_token))
          }, status: :created
        end
      end
    rescue ActiveRecord::RecordNotFound
      handle_create_error(code: "user_not_found", message: "Usuário informado não foi encontrado no tenant selecionado.")
    rescue ValidationError => error
      handle_create_error(code: "invalid_token_request", message: error.message)
    rescue ActiveRecord::RecordInvalid => error
      handle_create_error(code: "invalid_token_request", message: error.record.errors.full_messages.to_sentence)
    end

    def destroy
      token = revoke_token!

      respond_to do |format|
        format.html do
          redirect_to admin_api_access_tokens_path(tenant_id: @selected_tenant.id),
            notice: token.revoked_at.present? ? "Token revogado com sucesso." : "Token já estava revogado."
        end

        format.json do
          render json: {
            data: serialize_token(token).merge(revoked: token.revoked_at.present?)
          }
        end
      end
    rescue ActiveRecord::RecordNotFound
      respond_to do |format|
        format.html do
          redirect_to admin_api_access_tokens_path(tenant_id: @selected_tenant.id),
            alert: "Token não encontrado para o tenant selecionado."
        end

        format.json do
          render json: {
            error: {
              code: "not_found",
              message: "Token not found.",
              request_id: request.request_id
            }
          }, status: :not_found
        end
      end
    end

    private

    def ensure_ops_admin!
      return if Current.user&.role == "ops_admin"

      redirect_to root_path, alert: "Acesso restrito ao perfil de operação."
    end

    def require_passkey_step_up!
      return if Current.session&.admin_webauthn_verified_recently?

      redirect_to new_admin_passkey_verification_path(return_to: request.fullpath),
        alert: "Confirme a passkey para gerenciar tokens de integração."
    end

    def load_tenants!
      @tenants = Tenant.order(:slug).select(:id, :slug, :name, :active).to_a
    end

    def resolve_selected_tenant!
      requested_tenant_id = params[:tenant_id].presence || params.dig(:api_access_token, :tenant_id).presence || Current.user&.tenant_id
      @selected_tenant = @tenants.find { |tenant| tenant.id.to_s == requested_tenant_id.to_s }
      raise ActiveRecord::RecordNotFound if @selected_tenant.blank?
    end

    def list_tokens_for_selected_tenant
      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        ApiAccessToken
          .where(tenant_id: @selected_tenant.id)
          .includes(:user)
          .order(created_at: :desc)
          .limit(MAX_TOKENS)
          .map { |token| serialize_token(token) }
      end
    end

    def issue_token!
      attrs = token_create_params
      name = attrs.fetch(:name).to_s.strip
      raise ValidationError, "Nome do token é obrigatório." if name.blank?

      scopes = normalize_scopes(attrs.fetch(:scopes_input))
      raise ValidationError, "Informe pelo menos um escopo." if scopes.empty?

      expires_at = parse_expires_at(attrs[:expires_at])
      user_email = attrs[:user_email].to_s.strip.downcase

      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        tenant = Tenant.find(@selected_tenant.id)
        user = resolve_token_user(user_email)

        token, raw_token = ApiAccessToken.issue!(
          tenant: tenant,
          user: user,
          name: name,
          scopes: scopes,
          expires_at: expires_at,
          audit_context: audit_context_for_issue(tenant: tenant, user: user)
        )

        {
          token: token,
          raw_token: raw_token
        }
      end
    end

    def revoke_token!
      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        token = ApiAccessToken.lock.find_by!(tenant_id: @selected_tenant.id, id: params[:id])
        token.revoke!(audit_context: audit_context_for_revoke(token: token)) if token.revoked_at.blank?
        token
      end
    end

    def resolve_token_user(user_email)
      return nil if user_email.blank?

      User.find_by!(email_address: user_email)
    end

    def token_create_params
      params.require(:api_access_token).permit(
        :tenant_id,
        :name,
        :scopes_input,
        :expires_at,
        :user_email
      )
    end

    def normalize_scopes(raw)
      raw
        .to_s
        .split(/[\s,;]+/)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
        .sort
    end

    def parse_expires_at(raw)
      value = raw.to_s.strip
      return nil if value.blank?

      parsed = Time.zone.parse(value)
      raise ValidationError, "Data de expiração inválida." if parsed.blank?
      raise ValidationError, "Data de expiração deve estar no futuro." if parsed <= Time.current

      parsed
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

    def serialize_token(token)
      effective_user = token.effective_user
      {
        id: token.id,
        tenant_id: token.tenant_id,
        name: token.name,
        scopes: Array(token.scopes),
        user_id: token.user_id,
        user_uuid_id: token.user_uuid_id,
        user_email: effective_user&.email_address,
        created_at: token.created_at,
        expires_at: token.expires_at,
        revoked_at: token.revoked_at,
        last_used_at: token.last_used_at,
        active: token.active_now?
      }
    end

    def audit_context_for_issue(tenant:, user:)
      {
        actor_party_id: Current.user&.party_id,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        request_id: request.request_id,
        endpoint_path: request.fullpath,
        http_method: request.method,
        channel: "ADMIN",
        metadata: {
          "issued_for_tenant_id" => tenant.id,
          "issued_for_tenant_slug" => tenant.slug,
          "issued_for_user_id" => user&.id
        }
      }
    end

    def audit_context_for_revoke(token:)
      {
        actor_party_id: Current.user&.party_id,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        request_id: request.request_id,
        endpoint_path: request.fullpath,
        http_method: request.method,
        channel: "ADMIN",
        metadata: {
          "revoked_token_id" => token.id,
          "revoked_tenant_id" => token.tenant_id
        }
      }
    end

    def handle_create_error(code:, message:)
      respond_to do |format|
        format.html do
          flash.now[:alert] = message
          @tokens = list_tokens_for_selected_tenant
          render :index, status: :unprocessable_entity
        end

        format.json do
          render json: {
            error: {
              code: code,
              message: message,
              request_id: request.request_id
            }
          }, status: :unprocessable_entity
        end
      end
    end
  end
end
