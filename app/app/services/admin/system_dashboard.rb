module Admin
  class SystemDashboard
    DEFAULT_ROLE = "ops_admin".freeze
    INTEGER_ROW_FIELDS = %w[
      users_count
      hospital_count
      hospital_organization_count
      hospital_ownership_count
      receivable_count
      anticipation_count
      funded_anticipation_count
      settlement_count
      outbox_pending_count
      outbox_dead_letter_count
      reconciliation_open_count
      reconciliation_total_count
      direct_upload_count
    ].freeze
    DECIMAL_ROW_FIELDS = %w[
      receivable_gross_amount
      anticipation_requested_amount
      settlement_paid_amount
    ].freeze
    INTEGER_TOTAL_FIELDS = %w[
      users_count
      hospitals_count
      hospital_organizations_count
      receivables_count
      anticipations_count
      settlements_count
      outbox_pending_count
      outbox_dead_letter_count
      reconciliation_open_count
      reconciliation_total_count
      direct_upload_count
    ].freeze
    DECIMAL_TOTAL_FIELDS = %w[
      receivables_gross_amount
      anticipations_requested_amount
      settlements_paid_amount
    ].freeze
    INTEGER_TOTAL_SOURCE_KEYS = {
      users_count: :users_count,
      hospitals_count: :hospital_count,
      hospital_organizations_count: :hospital_organization_count,
      receivables_count: :receivable_count,
      anticipations_count: :anticipation_count,
      settlements_count: :settlement_count,
      outbox_pending_count: :outbox_pending_count,
      outbox_dead_letter_count: :outbox_dead_letter_count,
      reconciliation_open_count: :reconciliation_open_count,
      reconciliation_total_count: :reconciliation_total_count,
      direct_upload_count: :direct_upload_count
    }.freeze
    DECIMAL_TOTAL_SOURCE_KEYS = {
      receivables_gross_amount: :receivable_gross_amount,
      anticipations_requested_amount: :anticipation_requested_amount,
      settlements_paid_amount: :settlement_paid_amount
    }.freeze
    TENANT_METRIC_SELECTS = [
      " (SELECT COUNT(*) FROM users WHERE tenant_id = %{tenant_id}) AS users_count",
      " (SELECT COUNT(*) FROM parties WHERE tenant_id = %{tenant_id} AND kind = 'HOSPITAL') AS hospital_count",
      " (SELECT COUNT(DISTINCT organization_party_id) FROM hospital_ownerships WHERE tenant_id = %{tenant_id} AND active = TRUE) AS hospital_organization_count",
      " (SELECT COUNT(*) FROM hospital_ownerships WHERE tenant_id = %{tenant_id} AND active = TRUE) AS hospital_ownership_count",
      " (SELECT COUNT(*) FROM receivables WHERE tenant_id = %{tenant_id}) AS receivable_count",
      " (SELECT COALESCE(SUM(gross_amount), 0) FROM receivables WHERE tenant_id = %{tenant_id}) AS receivable_gross_amount",
      " (SELECT COUNT(*) FROM anticipation_requests WHERE tenant_id = %{tenant_id}) AS anticipation_count",
      " (SELECT COALESCE(SUM(requested_amount), 0) FROM anticipation_requests WHERE tenant_id = %{tenant_id}) AS anticipation_requested_amount",
      " (SELECT COUNT(*) FROM anticipation_requests WHERE tenant_id = %{tenant_id} AND status IN ('APPROVED', 'FUNDED', 'SETTLED')) AS funded_anticipation_count",
      " (SELECT COUNT(*) FROM receivable_payment_settlements WHERE tenant_id = %{tenant_id}) AS settlement_count",
      " (SELECT COALESCE(SUM(paid_amount), 0) FROM receivable_payment_settlements WHERE tenant_id = %{tenant_id}) AS settlement_paid_amount",
      <<~SQL.squish,
        (
          SELECT COUNT(*)
          FROM outbox_events events
          WHERE events.tenant_id = %{tenant_id}
            AND NOT EXISTS (
              SELECT 1
              FROM outbox_dispatch_attempts attempts
              WHERE attempts.tenant_id = events.tenant_id
                AND attempts.outbox_event_id = events.id
                AND attempts.status IN ('SENT', 'DEAD_LETTER')
            )
        ) AS outbox_pending_count
      SQL
      " (SELECT COUNT(*) FROM outbox_dispatch_attempts WHERE tenant_id = %{tenant_id} AND status = 'DEAD_LETTER') AS outbox_dead_letter_count",
      " (SELECT COUNT(*) FROM reconciliation_exceptions WHERE tenant_id = %{tenant_id} AND status = 'OPEN') AS reconciliation_open_count",
      " (SELECT COUNT(*) FROM reconciliation_exceptions WHERE tenant_id = %{tenant_id}) AS reconciliation_total_count",
      " (SELECT COUNT(*) FROM active_storage_blobs WHERE app_active_storage_blob_tenant_id(metadata) = CAST(%{tenant_id} AS uuid)) AS direct_upload_count",
      <<~SQL.squish
        (
          SELECT GREATEST(
            COALESCE((SELECT MAX(updated_at) FROM receivables WHERE tenant_id = %{tenant_id}), 'epoch'::timestamp),
            COALESCE((SELECT MAX(updated_at) FROM anticipation_requests WHERE tenant_id = %{tenant_id}), 'epoch'::timestamp),
            COALESCE((SELECT MAX(updated_at) FROM receivable_payment_settlements WHERE tenant_id = %{tenant_id}), 'epoch'::timestamp),
            COALESCE((SELECT MAX(last_seen_at) FROM reconciliation_exceptions WHERE tenant_id = %{tenant_id}), 'epoch'::timestamp),
            COALESCE((SELECT MAX(occurred_at) FROM action_ip_logs WHERE tenant_id = %{tenant_id}), 'epoch'::timestamp)
          )
        ) AS last_activity_at
      SQL
    ].freeze

    def initialize(actor_id:, role: DEFAULT_ROLE)
      @actor_id = actor_id
      @role = role.presence || DEFAULT_ROLE
    end

    def call
      tenants = load_tenants
      tenant_rows = build_tenant_rows(tenants)
      build_dashboard_payload(tenants: tenants, tenant_rows: tenant_rows)
    end

    private

    attr_reader :actor_id, :role

    def load_tenants
      Tenant.order(:slug).to_a
    end

    def build_tenant_rows(tenants)
      tenants.map { |tenant| build_tenant_row(tenant) }
    end

    def build_dashboard_payload(tenants:, tenant_rows:)
      {
        generated_at: Time.current,
        totals: build_totals(tenant_rows),
        tenant_rows: tenant_rows,
        recent_reconciliation_exceptions: build_recent_reconciliation_exceptions(tenants: tenants)
      }
    end

    def build_tenant_row(tenant)
      with_tenant_database_context(tenant_id: tenant.id, actor_id: actor_id, role: role) do
        metrics = tenant_metrics(tenant_id: tenant.id)
        build_tenant_row_payload(tenant: tenant, metrics: metrics)
      end
    end

    def build_tenant_row_payload(tenant:, metrics:)
      {
        tenant_id: tenant.id,
        tenant_slug: tenant.slug,
        tenant_name: tenant.name,
        tenant_active: tenant.active
      }.merge(integer_row_metrics(metrics)).merge(decimal_row_metrics(metrics)).merge(
        last_activity_at: time_value(metrics["last_activity_at"])
      )
    end

    def integer_row_metrics(metrics)
      INTEGER_ROW_FIELDS.each_with_object({}) do |field, output|
        output[field.to_sym] = integer_value(metrics[field])
      end
    end

    def decimal_row_metrics(metrics)
      DECIMAL_ROW_FIELDS.each_with_object({}) do |field, output|
        output[field.to_sym] = decimal_value(metrics[field])
      end
    end

    def build_totals(rows)
      {
        tenants_count: rows.size,
        active_tenants_count: active_tenants_count(rows)
      }.merge(integer_totals(rows)).merge(decimal_totals(rows)).merge(
        last_activity_at: rows.map { |row| row[:last_activity_at] }.compact.max
      )
    end

    def active_tenants_count(rows)
      rows.count { |row| row[:tenant_active] }
    end

    def integer_totals(rows)
      INTEGER_TOTAL_FIELDS.each_with_object({}) do |field, output|
        source_key = INTEGER_TOTAL_SOURCE_KEYS.fetch(field.to_sym)
        output[field.to_sym] = rows.sum { |row| row[source_key] }
      end
    end

    def decimal_totals(rows)
      DECIMAL_TOTAL_FIELDS.each_with_object({}) do |field, output|
        source_key = DECIMAL_TOTAL_SOURCE_KEYS.fetch(field.to_sym)
        output[field.to_sym] = rows.sum(BigDecimal("0")) { |row| row[source_key] }
      end
    end

    def build_recent_reconciliation_exceptions(tenants:, global_limit: 20, per_tenant_limit: 10)
      rows = tenants.flat_map { |tenant| recent_open_exceptions_for_tenant(tenant: tenant, per_tenant_limit: per_tenant_limit) }
      sort_and_limit_reconciliation_exceptions(rows: rows, global_limit: global_limit)
    end

    def recent_open_exceptions_for_tenant(tenant:, per_tenant_limit:)
      with_tenant_database_context(tenant_id: tenant.id, actor_id: actor_id, role: role) do
        ReconciliationException
          .where(tenant_id: tenant.id, status: "OPEN")
          .order(last_seen_at: :desc)
          .limit(per_tenant_limit)
          .map { |exception| reconciliation_exception_row(exception: exception, tenant: tenant) }
      end
    end

    def reconciliation_exception_row(exception:, tenant:)
      {
        tenant_id: tenant.id,
        tenant_slug: tenant.slug,
        tenant_name: tenant.name,
        source: exception.source,
        provider: exception.provider,
        external_event_id: exception.external_event_id,
        code: exception.code,
        message: exception.message,
        occurrences_count: exception.occurrences_count,
        first_seen_at: exception.first_seen_at,
        last_seen_at: exception.last_seen_at
      }
    end

    def sort_and_limit_reconciliation_exceptions(rows:, global_limit:)
      rows
        .sort_by { |row| row[:last_seen_at] || Time.at(0) }
        .reverse
        .first(global_limit)
    end

    def tenant_metrics(tenant_id:)
      quoted_tenant_id = ActiveRecord::Base.connection.quote(tenant_id)
      select_sql = tenant_metric_select_sql(quoted_tenant_id)
      ActiveRecord::Base.connection.select_one("SELECT #{select_sql}")
    end

    def tenant_metric_select_sql(quoted_tenant_id)
      TENANT_METRIC_SELECTS.map { |fragment| format(fragment, tenant_id: quoted_tenant_id) }.join(", ")
    end

    def integer_value(value)
      value.to_i
    end

    def decimal_value(value)
      BigDecimal(value.to_s)
    end

    def time_value(value)
      return nil if value.blank?
      return nil if value.to_s == "1970-01-01 00:00:00"

      value.in_time_zone
    end

    def with_tenant_database_context(tenant_id:, actor_id:, role:)
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction(requires_new: true) do
          set_database_context!("app.tenant_id", tenant_id)
          set_database_context!("app.actor_id", actor_id)
          set_database_context!("app.role", role)
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
