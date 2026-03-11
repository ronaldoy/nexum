require "digest"
require "securerandom"

module Admin
  class LoansController < BaseController
    PROFITABILITY_ACTION = Admin::FidcCockpit::PROFITABILITY_ACTION
    PROFITABILITY_ENTRY_KINDS = Admin::FidcCockpit::PROFITABILITY_ENTRY_KINDS
    LOANS_PER_PAGE = 20
    IMPORTED_SIGNATURE_METHOD = "ADMIN_IMPORTED_EVIDENCE".freeze
    IMPORTED_DOCUMENT_EVENT_TYPE = "DOCUMENT_IMPORTED".freeze
    MAX_IMPORTED_DOCUMENT_BYTES = 25.megabytes
    IMPORTED_DOCUMENT_CONTENT_TYPES = %w[application/pdf].freeze

    before_action :load_loan, only: %i[show approve fund settle record_document record_profitability]
    before_action :load_form_collections, only: %i[index show approve fund settle record_document record_profitability create]

    def index
      load_loan_index
    end

    def show
      @loan_row = cockpit.loan_row(@loan)
      @timeline_entries = timeline_entries_for(@loan)
    end

    def create
      ActiveRecord::Base.transaction do
        receivable_result = receivable_creation_service.call(receivable_payload)
        receivable = receivable_result.receivable
        receivable.update!(contract_reference: loan_params[:contract_reference]) if loan_params[:contract_reference].present?

        anticipation_result = anticipation_creation_service.call(
          anticipation_payload(receivable_result),
          default_requester_party_id: counterparty.id
        )

        redirect_to admin_loan_path(anticipation_result.anticipation_request), notice: "Empréstimo originado no cockpit."
      end
    rescue Receivables::Create::ValidationError, AnticipationRequests::Create::ValidationError => error
      load_loan_index
      flash.now[:alert] = error.message
      render :index, status: :unprocessable_entity
    rescue ActiveRecord::RecordInvalid => error
      load_loan_index
      flash.now[:alert] = error.record.errors.full_messages.to_sentence
      render :index, status: :unprocessable_entity
    end

    def approve
      with_loan_action_error_handling do
        ensure_status!(@loan, expected: "REQUESTED")
        transition_loan!(@loan, to: "APPROVED", event_type: "ANTICIPATION_APPROVED", action_type: "FIDC_LOAN_APPROVED")
        redirect_to admin_loan_path(@loan), notice: "Empréstimo aprovado."
      end
    end

    def fund
      with_loan_action_error_handling do
        ensure_status!(@loan, expected: "APPROVED")

        @loan.transition_status!(
          "FUNDED",
          funded_at: Time.current,
          metadata: {
            "funded_from" => "admin_cockpit",
            "funded_by_party_id" => Current.user&.party_id,
            "funded_at" => Time.current.utc.iso8601(6)
          }
        )
        @loan.receivable.update!(status: "FUNDED") unless @loan.receivable.status == "FUNDED"
        create_receivable_event!(
          receivable: @loan.receivable,
          event_type: "ANTICIPATION_FUNDED",
          payload: { "anticipation_request_id" => @loan.id, "status" => @loan.status }
        )
        FidcOperation.create!(
          tenant: admin_current_tenant,
          anticipation_request: @loan,
          provider: "MOCK",
          operation_type: "FUNDING_REQUEST",
          status: "SENT",
          amount: @loan.net_amount,
          currency: "BRL",
          idempotency_key: "cockpit-funding-#{@loan.id}-#{SecureRandom.hex(6)}",
          provider_reference: "cockpit-funding-#{@loan.id.first(8)}",
          requested_at: Time.current,
          processed_at: Time.current,
          metadata: {
            "source" => "admin_cockpit"
          }
        )
        log_action!(
          action_type: "FIDC_LOAN_FUNDED",
          target_type: "AnticipationRequest",
          target_id: @loan.id,
          metadata: { "receivable_id" => @loan.receivable_id, "net_amount" => @loan.net_amount.to_s("F") }
        )

        redirect_to admin_loan_path(@loan), notice: "Funding registrado."
      end
    end

    def settle
      with_loan_action_error_handling do
        ensure_fidc_counterparty_configured!

        Receivables::SettlePayment.new(
          tenant_id: admin_current_tenant.id,
          actor_party_id: Current.user&.party_id,
          actor_role: Current.role,
          request_id: request.request_id,
          idempotency_key: SecureRandom.uuid,
          request_ip: request.remote_ip,
          user_agent: request.user_agent,
          endpoint_path: request.fullpath,
          http_method: request.method
        ).call(
          receivable_id: @loan.receivable_id,
          receivable_allocation_id: @loan.receivable_allocation_id,
          paid_amount: settlement_params.fetch(:paid_amount),
          paid_at: parsed_timestamp(settlement_params.fetch(:paid_at)),
          payment_reference: settlement_params[:payment_reference].presence,
          metadata: {
            "source" => "admin_cockpit"
          }
        )

        redirect_to admin_loan_path(@loan), notice: "Liquidação registrada."
      end
    end

    def record_document
      with_loan_action_error_handling do
        uploaded_artifact = uploaded_document_artifact!
        document = Document.create!(
          tenant: admin_current_tenant,
          receivable: @loan.receivable,
          actor_party_id: Current.user&.party_id,
          document_type: document_params.fetch(:document_type),
          signature_method: IMPORTED_SIGNATURE_METHOD,
          status: "SIGNED",
          sha256: uploaded_artifact.fetch(:sha256),
          storage_key: uploaded_artifact.fetch(:blob).key,
          signed_at: parsed_timestamp(document_params.fetch(:signed_at)),
          metadata: {
            "provider_envelope_id" => document_params[:provider_envelope_id],
            "source" => "admin_cockpit_import",
            "imported_by_party_id" => Current.user&.party_id
          }.compact
        )
        document.file.attach(uploaded_artifact.fetch(:blob))
        DocumentEvent.create!(
          tenant: admin_current_tenant,
          document: document,
          receivable: @loan.receivable,
          actor_party_id: Current.user&.party_id,
          event_type: IMPORTED_DOCUMENT_EVENT_TYPE,
          occurred_at: document.signed_at,
          request_id: request.request_id,
          payload: {
            "document_type" => document.document_type,
            "provider_envelope_id" => document_params[:provider_envelope_id],
            "signature_method" => document.signature_method
          }.compact
        )
        create_receivable_event!(
          receivable: @loan.receivable,
          event_type: "RECEIVABLE_DOCUMENT_ATTACHED",
          payload: {
            "anticipation_request_id" => @loan.id,
            "document_id" => document.id,
            "document_type" => document.document_type,
            "signature_method" => document.signature_method
          }
        )
        log_action!(
          action_type: "FIDC_LOAN_DOCUMENT_IMPORTED",
          target_type: "Document",
          target_id: document.id,
          metadata: { "anticipation_request_id" => @loan.id, "receivable_id" => @loan.receivable_id }
        )

        redirect_to admin_loan_path(@loan), notice: "Documento importado com evidência anexada."
      end
    end

    def record_profitability
      with_loan_action_error_handling do
        entry_kind = profitability_params.fetch(:entry_kind)
        amount = normalized_money(profitability_params.fetch(:amount))
        unless PROFITABILITY_ENTRY_KINDS.include?(entry_kind)
          @loan.errors.add(:base, "Tipo de rentabilidade inválido.")
          raise ActiveRecord::RecordInvalid.new(@loan)
        end
        if amount <= 0
          @loan.errors.add(:base, "Informe um valor positivo para a rentabilidade.")
          raise ActiveRecord::RecordInvalid.new(@loan)
        end

        log_action!(
          action_type: PROFITABILITY_ACTION,
          target_type: "AnticipationRequest",
          target_id: @loan.id,
          occurred_at: profitability_occurred_at,
          metadata: {
            "entry_kind" => entry_kind,
            "category" => profitability_params.fetch(:category),
            "amount" => amount.to_s("F"),
            "currency" => "BRL",
            "occurred_on" => profitability_params.fetch(:occurred_on),
            "note" => profitability_params[:note]
          }
        )

        redirect_to admin_loan_path(@loan), notice: "Rentabilidade registrada."
      end
    end

    private

    def cockpit
      @cockpit ||= Admin::FidcCockpit.new(tenant: admin_current_tenant)
    end

    def current_page
      [ params.fetch(:page, 1).to_i, 1 ].max
    end

    def current_structure_filter
      candidate = params[:loan_structure].to_s
      return nil unless Admin::FidcCockpit::LOAN_STRUCTURE_FILTER_KINDS.key?(candidate)

      candidate
    end

    def load_loan_index
      page_bundle = cockpit.paginated_loan_rows(
        page: current_page,
        per_page: LOANS_PER_PAGE,
        structure: current_structure_filter
      )
      @loan_rows = page_bundle.fetch(:rows)
      @loan_pagination = page_bundle.fetch(:pagination)
      @loan_structure_filter = current_structure_filter
    end

    def load_form_collections
      @hospitals = Party.where(tenant_id: admin_current_tenant.id, kind: "HOSPITAL").order(:legal_name)
      @counterparties = Party.where(tenant_id: admin_current_tenant.id, kind: %w[SUPPLIER LEGAL_ENTITY_PJ PHYSICIAN_PF FIDC]).order(:legal_name)
      @receivable_kinds = ReceivableKind.where(tenant_id: admin_current_tenant.id, active: true).order(:name)
      @stage_definitions = Admin::FidcCockpit::STAGE_DEFINITIONS
    end

    def load_loan
      @loan = AnticipationRequest
        .where(tenant_id: admin_current_tenant.id)
        .includes(
          :requester_party,
          :anticipation_settlement_entries,
          receivable_allocation: %i[allocated_party physician_party],
          receivable: %i[debtor_party creditor_party beneficiary_party receivable_kind documents receivable_events]
        )
        .find(params[:id])
    end

    def receivable_creation_service
      @receivable_creation_service ||= Receivables::Create.new(
        tenant_id: admin_current_tenant.id,
        actor_role: Current.role,
        request_id: request.request_id,
        idempotency_key: SecureRandom.uuid,
        request_ip: request.remote_ip,
        user_agent: request.user_agent,
        endpoint_path: request.fullpath,
        http_method: request.method
      )
    end

    def anticipation_creation_service
      @anticipation_creation_service ||= AnticipationRequests::Create.new(
        tenant_id: admin_current_tenant.id,
        actor_role: Current.role,
        request_id: request.request_id,
        idempotency_key: SecureRandom.uuid,
        request_ip: request.remote_ip,
        user_agent: request.user_agent,
        endpoint_path: request.fullpath,
        http_method: request.method
      )
    end

    def receivable_payload
      {
        external_reference: loan_params[:external_reference].presence || generated_external_reference,
        receivable_kind_code: receivable_kind.code,
        debtor_party_id: hospital.id,
        creditor_party_id: counterparty.id,
        beneficiary_party_id: counterparty.id,
        gross_amount: normalized_money(loan_params.fetch(:gross_amount)).to_s("F"),
        currency: "BRL",
        performed_at: parsed_timestamp(loan_params.fetch(:performed_at)),
        due_at: parsed_timestamp(loan_params.fetch(:due_at)),
        metadata: {
          "source" => "admin_cockpit",
          "loan_name" => loan_params[:loan_name]
        }.compact,
        allocation: {
          "allocated_party_id" => counterparty.id,
          "gross_amount" => normalized_money(loan_params.fetch(:gross_amount)).to_s("F"),
          "eligible_for_anticipation" => true
        }
      }
    end

    def anticipation_payload(receivable_result)
      {
        receivable_id: receivable_result.receivable.id,
        receivable_allocation_id: receivable_result.allocation.id,
        requester_party_id: counterparty.id,
        requested_amount: normalized_money(loan_params.fetch(:requested_amount)).to_s("F"),
        discount_rate: normalized_rate(loan_params.fetch(:discount_rate)).to_s("F"),
        channel: "INTERNAL",
        metadata: {
          "source" => "admin_cockpit",
          "loan_name" => loan_params[:loan_name],
          "contract_reference" => loan_params[:contract_reference]
        }.compact
      }
    end

    def transition_loan!(loan, to:, event_type:, action_type:)
      loan.transition_status!(
        to,
        metadata: {
          "updated_from" => "admin_cockpit",
          "updated_by_party_id" => Current.user&.party_id,
          "updated_at" => Time.current.utc.iso8601(6)
        }
      )
      create_receivable_event!(
        receivable: loan.receivable,
        event_type: event_type,
        payload: { "anticipation_request_id" => loan.id, "status" => to }
      )
      log_action!(
        action_type: action_type,
        target_type: "AnticipationRequest",
        target_id: loan.id,
        metadata: { "receivable_id" => loan.receivable_id }
      )
    end

    def create_receivable_event!(receivable:, event_type:, payload:)
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous.fetch(0) + 1 : 1
      prev_hash = previous&.fetch(1)
      occurred_at = Time.current
      serialized_payload = payload.transform_keys(&:to_s)
      event_hash = Digest::SHA256.hexdigest(
        [
          receivable.id,
          sequence,
          event_type,
          occurred_at.utc.iso8601(6),
          request.request_id,
          prev_hash,
          serialized_payload.to_json
        ].join("|")
      )

      ReceivableEvent.create!(
        tenant: admin_current_tenant,
        receivable: receivable,
        sequence: sequence,
        event_type: event_type,
        actor_party_id: Current.user&.party_id,
        actor_role: Current.role,
        occurred_at: occurred_at,
        request_id: request.request_id,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: serialized_payload
      )
    end

    def timeline_entries_for(loan)
      profitability_entries = cockpit.send(:profitability_totals_for, loan.id).fetch(:entries)
      document_entries = loan.receivable.documents.map do |document|
        {
          happened_at: document.signed_at,
          category: "Documento",
          title: document.signature_method == IMPORTED_SIGNATURE_METHOD ? "Documento importado" : "Contrato assinado",
          details: document.document_type
        }
      end
      receivable_event_entries = loan.receivable.receivable_events.map do |event|
        {
          happened_at: event.occurred_at,
          category: "Fluxo",
          title: event.event_type.tr("_", " ").capitalize,
          details: event.payload.to_json
        }
      end
      settlement_entries = loan.anticipation_settlement_entries.map do |entry|
        {
          happened_at: entry.settled_at,
          category: "Liquidação",
          title: "Repasse liquidado",
          details: "Valor liquidado #{entry.settled_amount.to_d.to_s("F")}"
        }
      end
      profitability_timeline = profitability_entries.map do |entry|
        {
          happened_at: entry[:occurred_at],
          category: "Rentabilidade",
          title: entry[:entry_kind] == "INCOME" ? "Receita registrada" : "Despesa registrada",
          details: "#{entry[:category]} · #{entry[:amount].to_s("F")}"
        }
      end

      (document_entries + receivable_event_entries + settlement_entries + profitability_timeline)
        .sort_by { |entry| entry[:happened_at] || Time.at(0) }
        .reverse
    end

    def log_action!(action_type:, target_type:, target_id:, metadata:, occurred_at: Time.current)
      ActionIpLog.create!(
        tenant: admin_current_tenant,
        actor_party_id: Current.user&.party_id,
        action_type: action_type,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        request_id: request.request_id,
        endpoint_path: request.fullpath,
        http_method: request.method,
        channel: "ADMIN",
        target_type: target_type,
        target_id: target_id,
        success: true,
        occurred_at: occurred_at,
        metadata: metadata.compact.transform_keys(&:to_s)
      )
    end

    def ensure_status!(loan, expected:)
      return if loan.status == expected

      loan.errors.add(:base, "Status inválido para a ação.")
      raise ActiveRecord::RecordInvalid.new(loan)
    end

    def normalized_money(value)
      FinancialRounding.money(BigDecimal(value.to_s.tr(",", ".")))
    rescue ArgumentError
      BigDecimal("0")
    end

    def normalized_rate(value)
      FinancialRounding.rate(BigDecimal(value.to_s.tr(",", ".")))
    rescue ArgumentError
      BigDecimal("0")
    end

    def parsed_timestamp(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      Time.current
    end

    def generated_external_reference
      "AVR-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(3).upcase}"
    end

    def profitability_occurred_at
      Time.zone.parse("#{profitability_params.fetch(:occurred_on)} 12:00")
    rescue ArgumentError
      Time.current
    end

    def ensure_fidc_counterparty_configured!
      return if Party.exists?(tenant_id: admin_current_tenant.id, kind: "FIDC")

      @loan.errors.add(:base, "Cadastre a contraparte FIDC antes de liquidar a operação.")
      raise ActiveRecord::RecordInvalid.new(@loan)
    end

    def loan_params
      params.require(:loan).permit(
        :loan_name,
        :external_reference,
        :contract_reference,
        :receivable_kind_id,
        :debtor_party_id,
        :counterparty_id,
        :gross_amount,
        :requested_amount,
        :discount_rate,
        :performed_at,
        :due_at
      )
    end

    def settlement_params
      params.require(:settlement).permit(:paid_amount, :paid_at, :payment_reference)
    end

    def document_params
      params.require(:document).permit(:document_type, :provider_envelope_id, :signed_at, :file)
    end

    def uploaded_document_artifact!
      uploaded_file = document_params[:file]
      if uploaded_file.blank?
        @loan.errors.add(:base, "Anexe o arquivo do documento.")
        raise ActiveRecord::RecordInvalid.new(@loan)
      end

      content_type = uploaded_file.content_type.to_s
      unless IMPORTED_DOCUMENT_CONTENT_TYPES.include?(content_type)
        @loan.errors.add(:base, "Envie o documento em PDF.")
        raise ActiveRecord::RecordInvalid.new(@loan)
      end

      if uploaded_file.size.to_i <= 0 || uploaded_file.size.to_i > MAX_IMPORTED_DOCUMENT_BYTES
        @loan.errors.add(:base, "O arquivo do documento deve ter até 25 MB.")
        raise ActiveRecord::RecordInvalid.new(@loan)
      end

      checksum = Digest::SHA256.hexdigest(uploaded_file.read.to_s)
      uploaded_file.rewind

      blob = ActiveStorage::Blob.create_and_upload!(
        io: uploaded_file,
        filename: uploaded_file.original_filename.presence || "documento-importado.pdf",
        content_type: content_type,
        metadata: {
          "tenant_id" => admin_current_tenant.id.to_s,
          "source" => "admin_cockpit_import"
        }
      )

      {
        blob: blob,
        sha256: checksum
      }
    end

    def profitability_params
      params.require(:profitability).permit(:entry_kind, :category, :amount, :occurred_on, :note)
    end

    def receivable_kind
      @receivable_kind ||= ReceivableKind.where(tenant_id: admin_current_tenant.id).find(loan_params.fetch(:receivable_kind_id))
    end

    def hospital
      @hospital ||= Party.where(tenant_id: admin_current_tenant.id, kind: "HOSPITAL").find(loan_params.fetch(:debtor_party_id))
    end

    def counterparty
      @counterparty ||= Party.where(tenant_id: admin_current_tenant.id).find(loan_params.fetch(:counterparty_id))
    end

    def with_loan_action_error_handling
      yield
    rescue ActiveRecord::RecordInvalid => error
      load_form_collections
      @loan_row = cockpit.loan_row(@loan)
      @timeline_entries = timeline_entries_for(@loan)
      flash.now[:alert] = error.record.errors.full_messages.to_sentence.presence || error.message
      render :show, status: :unprocessable_entity
    rescue StandardError => error
      load_form_collections
      @loan_row = cockpit.loan_row(@loan)
      @timeline_entries = timeline_entries_for(@loan)
      flash.now[:alert] = error.message
      render :show, status: :unprocessable_entity
    end
  end
end
