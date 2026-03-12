module Admin
  class PaymentsController < BaseController
    PAYOUTS_PER_PAGE = 20

    def index
      snapshot = dashboard.call(page: current_page, per_page: PAYOUTS_PER_PAGE, status: current_status_filter)
      @generated_at = snapshot.fetch(:generated_at)
      @headline_cards = snapshot.fetch(:headline_cards)
      @payout_rows = snapshot.fetch(:payout_rows)
      @payout_pagination = snapshot.fetch(:payout_pagination)
      @batch_rows = snapshot.fetch(:batch_rows)
      @failure_rows = snapshot.fetch(:failure_rows)
      @payment_instruction_monitor_cards = snapshot.fetch(:payment_instruction_monitor_cards)
      @payment_instruction_event_rows = snapshot.fetch(:payment_instruction_event_rows)
      @active_status = snapshot.fetch(:active_status)
    end

    def replay_instruction_event
      replayed_event = replay_service.call(outbox_event_id: params.fetch(:outbox_event_id))
      redirect_to(
        admin_payments_path(status: current_status_filter, page: current_page),
        notice: "Evento #{replayed_event.event_type} reenfileirado para novo dispatch."
      )
    rescue KeyError
      redirect_to admin_payments_path(status: current_status_filter, page: current_page), alert: "Selecione um evento válido para replay."
    rescue Admin::ReplayPaymentInstructionEvent::ValidationError => error
      redirect_to admin_payments_path(status: current_status_filter, page: current_page), alert: error.message
    end

    private

    def dashboard
      @dashboard ||= Admin::PaymentsDashboard.new(tenant: admin_current_tenant)
    end

    def replay_service
      @replay_service ||= Admin::ReplayPaymentInstructionEvent.new(
        tenant: admin_current_tenant,
        actor: Current.user,
        request_id: request.request_id,
        request_ip: request.remote_ip,
        user_agent: request.user_agent,
        endpoint_path: request.path
      )
    end

    def current_page
      [ params.fetch(:page, 1).to_i, 1 ].max
    end

    def current_status_filter
      candidate = params[:status].to_s
      return nil unless Admin::PaymentsDashboard::STATUS_FILTERS.key?(candidate)

      candidate
    end
  end
end
