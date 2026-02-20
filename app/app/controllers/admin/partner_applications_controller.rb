module Admin
  class PartnerApplicationsController < ApplicationController
    DEFAULT_TOKEN_TTL_MINUTES = 15
    MAX_ROWS = 200
    SUPPORTED_SCOPES = PartnerApplication::ALLOWED_SCOPES.freeze
    PARTNER_APPLICATION_PERMITTED_FIELDS = %i[
      tenant_id
      name
      scopes_input
      token_ttl_minutes
      allowed_origins_input
    ].freeze

    class ValidationError < StandardError; end

    before_action :ensure_ops_admin!
    before_action :require_passkey_step_up!
    before_action :load_tenants!
    before_action :resolve_selected_tenant!

    def index
      @supported_scopes = SUPPORTED_SCOPES
      @partner_applications = list_partner_applications
    end

    def create
      with_validation_error_handling do
        render_create_success(issue_partner_application!)
      end
    end

    def rotate_secret
      application, client_secret = rotate_partner_application_secret!
      render_rotate_secret_success(application:, client_secret:)
    rescue ActiveRecord::RecordNotFound
      handle_not_found
    end

    def deactivate
      render_deactivate_success(deactivate_partner_application!)
    rescue ActiveRecord::RecordNotFound
      handle_not_found
    end

    private

    def with_validation_error_handling
      yield
    rescue ValidationError => error
      handle_validation_error(code: "invalid_partner_application_request", message: error.message)
    rescue ActiveRecord::RecordInvalid => error
      handle_validation_error(code: "invalid_partner_application_request", message: error.record.errors.full_messages.to_sentence)
    end

    def ensure_ops_admin!
      return if Current.user&.role == "ops_admin"

      redirect_to root_path, alert: "Acesso restrito ao perfil de operação."
    end

    def require_passkey_step_up!
      return if Current.session&.admin_webauthn_verified_recently?

      redirect_to new_admin_passkey_verification_path(return_to: request.fullpath),
        alert: "Confirme a passkey para gerenciar aplicações parceiras."
    end

    def load_tenants!
      @tenants = Tenant.order(:slug).select(:id, :slug, :name, :active).to_a
    end

    def resolve_selected_tenant!
      requested_tenant_id = params[:tenant_id].presence || params.dig(:partner_application, :tenant_id).presence || Current.user&.tenant_id
      @selected_tenant = @tenants.find { |tenant| tenant.id.to_s == requested_tenant_id.to_s }
      raise ActiveRecord::RecordNotFound if @selected_tenant.blank?
    end

    def list_partner_applications
      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        PartnerApplication
          .where(tenant_id: @selected_tenant.id)
          .order(created_at: :desc)
          .limit(MAX_ROWS)
          .map { |application| serialize_partner_application(application) }
      end
    end

    def issue_partner_application!
      attrs = partner_application_params
      issue_partner_application_for_selected_tenant!(
        name: validated_application_name(attrs.fetch(:name)),
        scopes: validated_scopes(attrs.fetch(:scopes_input)),
        token_ttl_minutes: normalize_token_ttl(attrs[:token_ttl_minutes]),
        allowed_origins: normalize_allowed_origins(attrs[:allowed_origins_input])
      )
    end

    def rotate_partner_application_secret!
      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        application = PartnerApplication.lock.find_by!(tenant_id: @selected_tenant.id, id: params[:id])
        client_secret = application.rotate_secret!(audit_context: lifecycle_audit_context)
        [ application, client_secret ]
      end
    end

    def deactivate_partner_application!
      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        application = PartnerApplication.lock.find_by!(tenant_id: @selected_tenant.id, id: params[:id])
        application.deactivate!(audit_context: lifecycle_audit_context)
        application
      end
    end

    def issue_partner_application_for_selected_tenant!(name:, scopes:, token_ttl_minutes:, allowed_origins:)
      with_tenant_database_context(tenant_id: @selected_tenant.id) do
        tenant = Tenant.find(@selected_tenant.id)
        application, client_secret = PartnerApplication.issue!(
          tenant: tenant,
          created_by_user: Current.user,
          name: name,
          scopes: scopes,
          token_ttl_minutes: token_ttl_minutes,
          allowed_origins: allowed_origins,
          audit_context: lifecycle_audit_context(metadata: issue_audit_metadata(tenant))
        )
        { application: application, client_secret: client_secret }
      end
    end

    def validated_application_name(raw_name)
      name = raw_name.to_s.strip
      raise ValidationError, "Nome da aplicação é obrigatório." if name.blank?

      name
    end

    def validated_scopes(raw_scopes)
      scopes = normalize_scopes(raw_scopes)
      raise ValidationError, "Informe ao menos um escopo permitido." if scopes.empty?

      scopes
    end

    def lifecycle_audit_context(metadata: {})
      base_lifecycle_audit_context.merge(metadata: metadata)
    end

    def base_lifecycle_audit_context
      {
        actor_party_id: Current.user&.party_id,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        request_id: request.request_id,
        endpoint_path: request.fullpath,
        http_method: request.method,
        channel: "ADMIN"
      }
    end

    def issue_audit_metadata(tenant)
      {
        "issued_for_tenant_id" => tenant.id,
        "issued_for_tenant_slug" => tenant.slug
      }
    end

    def partner_application_params
      params.require(:partner_application).permit(*PARTNER_APPLICATION_PERMITTED_FIELDS)
    end

    def normalize_scopes(raw)
      scopes = raw
        .to_s
        .split(/[\s,;]+/)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
        .sort

      unknown_scopes = scopes - SUPPORTED_SCOPES
      if unknown_scopes.any?
        raise ValidationError, "Escopos inválidos: #{unknown_scopes.join(', ')}."
      end

      scopes
    end

    def normalize_token_ttl(raw)
      value = Integer(raw, exception: false)
      return DEFAULT_TOKEN_TTL_MINUTES if value.blank?
      return value if value.between?(5, 60)

      raise ValidationError, "TTL do token deve estar entre 5 e 60 minutos."
    end

    def normalize_allowed_origins(raw)
      values = raw
        .to_s
        .split(/[\n,;\s]+/)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
        .sort

      values.each do |origin|
        uri = URI.parse(origin)
        next if uri.is_a?(URI::HTTPS) && uri.host.present?

        raise ValidationError, "Origem permitida inválida: #{origin}"
      rescue URI::InvalidURIError
        raise ValidationError, "Origem permitida inválida: #{origin}"
      end

      values
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

    def render_create_success(issued)
      application = issued.fetch(:application)
      client_secret = issued.fetch(:client_secret)

      render_partner_application_success(
        application: application,
        status: :created,
        notice: "Aplicação parceira criada com sucesso.",
        client_secret: client_secret
      )
    end

    def render_rotate_secret_success(application:, client_secret:)
      render_partner_application_success(
        application: application,
        status: :ok,
        notice: "Segredo rotacionado com sucesso.",
        client_secret: client_secret
      )
    end

    def render_deactivate_success(application)
      render_partner_application_success(
        application: application,
        status: :ok,
        notice: "Aplicação parceira desativada."
      )
    end

    def render_partner_application_success(application:, status:, notice:, client_secret: nil)
      respond_to do |format|
        format.html do
          flash[:notice] = notice
          assign_partner_application_secret_flash(application:, client_secret:)
          redirect_to selected_tenant_partner_applications_path
        end

        format.json do
          payload = serialize_partner_application(application)
          payload[:client_secret] = client_secret if client_secret.present?
          render json: { data: payload }, status: status
        end
      end
    end

    def assign_partner_application_secret_flash(application:, client_secret:)
      return if client_secret.blank?

      flash[:partner_application_client_id] = application.client_id
      flash[:partner_application_client_secret] = client_secret
    end

    def selected_tenant_partner_applications_path
      admin_partner_applications_path(tenant_id: @selected_tenant.id)
    end

    def serialize_partner_application(application)
      {
        id: application.id,
        tenant_id: application.tenant_id,
        name: application.name,
        client_id: application.client_id,
        scopes: Array(application.scopes),
        token_ttl_minutes: application.token_ttl_minutes,
        allowed_origins: Array(application.allowed_origins),
        active: application.active,
        last_used_at: application.last_used_at,
        rotated_at: application.rotated_at,
        created_at: application.created_at
      }
    end

    def handle_validation_error(code:, message:)
      respond_to do |format|
        format.html do
          flash.now[:alert] = message
          @supported_scopes = SUPPORTED_SCOPES
          @partner_applications = list_partner_applications
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

    def handle_not_found
      respond_to do |format|
        format.html do
          redirect_to selected_tenant_partner_applications_path,
            alert: "Aplicação parceira não encontrada para o tenant selecionado."
        end

        format.json do
          render json: {
            error: {
              code: "not_found",
              message: "Partner application not found.",
              request_id: request.request_id
            }
          }, status: :not_found
        end
      end
    end
  end
end
