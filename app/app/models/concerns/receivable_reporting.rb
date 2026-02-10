module ReceivableReporting
  extend ActiveSupport::Concern

  class_methods do
    def by_kind(kind_code)
      joins(:receivable_kind).where(receivable_kinds: { code: kind_code })
    end

    def within_due_range(start_at:, end_at:)
      where(due_at: start_at..end_at)
    end

    # Shared aggregate metrics across all receivable kinds.
    def aggregate_totals(tenant_id:, start_at:, end_at:)
      where(tenant_id: tenant_id)
        .within_due_range(start_at: start_at, end_at: end_at)
        .group(:receivable_kind_id, :status)
        .select(
          :receivable_kind_id,
          :status,
          "COUNT(*) AS receivable_count",
          "COALESCE(SUM(gross_amount), 0) AS gross_amount_total"
        )
    end
  end
end
