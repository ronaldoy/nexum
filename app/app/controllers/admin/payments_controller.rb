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
      @active_status = snapshot.fetch(:active_status)
    end

    private

    def dashboard
      @dashboard ||= Admin::PaymentsDashboard.new(tenant: admin_current_tenant)
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
