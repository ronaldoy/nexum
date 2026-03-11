module Admin
  class CounterpartiesController < BaseController
    before_action :load_supporting_rows, only: :index

    def index
      @parties = Party.where(tenant_id: admin_current_tenant.id).order(created_at: :desc).limit(100)
    end

    def create
      ActiveRecord::Base.transaction do
        party = create_party!
        create_physician_profile!(party) if physician_kind?
        log_counterparty_creation!(party)
      end

      redirect_to admin_counterparties_path, notice: "Contraparte criada com sucesso."
    rescue ActiveRecord::RecordInvalid => error
      @parties = Party.where(tenant_id: admin_current_tenant.id).order(created_at: :desc).limit(100)
      load_supporting_rows
      flash.now[:alert] = error.record.errors.full_messages.to_sentence
      render :index, status: :unprocessable_entity
    end

    def link_hospital
      HospitalOwnership.create!(
        tenant: admin_current_tenant,
        organization_party_id: ownership_params.fetch(:organization_party_id),
        hospital_party_id: ownership_params.fetch(:hospital_party_id),
        active: true,
        metadata: {
          "source" => "admin_cockpit",
          "linked_at" => Time.current.utc.iso8601(6)
        }
      )

      redirect_to admin_counterparties_path, notice: "Vínculo hospital-organização criado."
    rescue ActiveRecord::RecordInvalid => error
      @parties = Party.where(tenant_id: admin_current_tenant.id).order(created_at: :desc).limit(100)
      load_supporting_rows
      flash.now[:alert] = error.record.errors.full_messages.to_sentence
      render :index, status: :unprocessable_entity
    end

    private

    def load_supporting_rows
      @hospital_rows = Party.where(tenant_id: admin_current_tenant.id, kind: "HOSPITAL").order(:legal_name)
      @organization_rows = Party.where(tenant_id: admin_current_tenant.id, kind: "LEGAL_ENTITY_PJ").order(:legal_name)
      @ownership_rows = HospitalOwnership
        .where(tenant_id: admin_current_tenant.id, active: true)
        .includes(:organization_party, :hospital_party)
        .order(created_at: :desc)
        .limit(20)
    end

    def create_party!
      Party.create!(
        tenant: admin_current_tenant,
        kind: counterparty_params.fetch(:kind),
        document_type: document_type_for(counterparty_params.fetch(:kind)),
        document_number: counterparty_params.fetch(:document_number),
        legal_name: counterparty_params.fetch(:legal_name),
        display_name: counterparty_params[:display_name],
        external_ref: counterparty_params[:external_ref],
        metadata: {
          "source" => "admin_cockpit"
        }
      )
    end

    def create_physician_profile!(party)
      Physician.create!(
        tenant: admin_current_tenant,
        party: party,
        full_name: counterparty_params.fetch(:legal_name),
        email: physician_details_params[:email],
        phone: physician_details_params[:phone],
        crm_number: physician_details_params[:crm_number],
        crm_state: physician_details_params[:crm_state],
        metadata: {
          "source" => "admin_cockpit"
        }
      )
    end

    def log_counterparty_creation!(party)
      ActionIpLog.create!(
        tenant: admin_current_tenant,
        actor_party_id: Current.user&.party_id,
        action_type: "FIDC_COUNTERPARTY_CREATED",
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        request_id: request.request_id,
        endpoint_path: request.fullpath,
        http_method: request.method,
        channel: "ADMIN",
        target_type: "Party",
        target_id: party.id,
        success: true,
        occurred_at: Time.current,
        metadata: {
          "kind" => party.kind,
          "document_type" => party.document_type,
          "document_number" => party.document_number
        }
      )
    end

    def physician_kind?
      counterparty_params.fetch(:kind) == "PHYSICIAN_PF"
    end

    def document_type_for(kind)
      kind == "PHYSICIAN_PF" ? "CPF" : "CNPJ"
    end

    def counterparty_params
      params.require(:counterparty).permit(:kind, :legal_name, :display_name, :document_number, :external_ref)
    end

    def physician_details_params
      params.fetch(:counterparty, {}).permit(:email, :phone, :crm_number, :crm_state)
    end

    def ownership_params
      params.require(:hospital_ownership).permit(:organization_party_id, :hospital_party_id)
    end
  end
end
