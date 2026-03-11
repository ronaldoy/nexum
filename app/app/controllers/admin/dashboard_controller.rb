module Admin
  class DashboardController < BaseController
    LOANS_PER_PAGE = 20

    helper_method :ops_admin?

    def show
      snapshot = cockpit.call(
        recent_limit: LOANS_PER_PAGE,
        recent_page: current_page,
        recent_structure: current_structure_filter
      )
      @generated_at = snapshot.fetch(:generated_at)
      @tenant = snapshot.fetch(:tenant)
      @headline_cards = snapshot.fetch(:headline_cards)
      @stage_cards = snapshot.fetch(:stage_cards)
      @stage_volume_chart = snapshot.fetch(:stage_volume_chart)
      @commercial_highlights = snapshot.fetch(:commercial_highlights)
      @recent_loans = snapshot.fetch(:recent_loans)
      @loan_pagination = snapshot.fetch(:recent_loans_pagination)
      @loan_structure_filter = current_structure_filter
      @counterparty_rows = snapshot.fetch(:counterparty_rows)
      @profitability_entries = snapshot.fetch(:profitability_entries)
      @risk_signals = snapshot.fetch(:risk_signals)
      @reconciliation_exceptions = snapshot.fetch(:reconciliation_exceptions)
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

    def ops_admin?
      Current.user&.role == "ops_admin"
    end
  end
end
