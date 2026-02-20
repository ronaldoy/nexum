module Admin
  class SystemDashboard
    DEFAULT_ROLE = "ops_admin".freeze

    def initialize(actor_id:, role: DEFAULT_ROLE)
      @actor_id = actor_id
      @role = role.presence || DEFAULT_ROLE
    end

    def call
      tenants = Tenant.order(:slug).to_a
      tenant_rows = tenants.map { |tenant| build_tenant_row(tenant) }

      {
        generated_at: Time.current,
        totals: build_totals(tenant_rows),
        tenant_rows: tenant_rows,
        recent_reconciliation_exceptions: build_recent_reconciliation_exceptions(tenants: tenants)
      }
    end

    private

    attr_reader :actor_id, :role

    def build_tenant_row(tenant)
      with_tenant_database_context(tenant_id: tenant.id, actor_id: actor_id, role: role) do
        metrics = tenant_metrics(tenant_id: tenant.id)

        {
          tenant_id: tenant.id,
          tenant_slug: tenant.slug,
          tenant_name: tenant.name,
          tenant_active: tenant.active,
          users_count: integer_value(metrics["users_count"]),
          hospital_count: integer_value(metrics["hospital_count"]),
          hospital_organization_count: integer_value(metrics["hospital_organization_count"]),
          hospital_ownership_count: integer_value(metrics["hospital_ownership_count"]),
          receivable_count: integer_value(metrics["receivable_count"]),
          receivable_gross_amount: decimal_value(metrics["receivable_gross_amount"]),
          anticipation_count: integer_value(metrics["anticipation_count"]),
          anticipation_requested_amount: decimal_value(metrics["anticipation_requested_amount"]),
          funded_anticipation_count: integer_value(metrics["funded_anticipation_count"]),
          settlement_count: integer_value(metrics["settlement_count"]),
          settlement_paid_amount: decimal_value(metrics["settlement_paid_amount"]),
          outbox_pending_count: integer_value(metrics["outbox_pending_count"]),
          outbox_dead_letter_count: integer_value(metrics["outbox_dead_letter_count"]),
          reconciliation_open_count: integer_value(metrics["reconciliation_open_count"]),
          reconciliation_total_count: integer_value(metrics["reconciliation_total_count"]),
          direct_upload_count: integer_value(metrics["direct_upload_count"]),
          last_activity_at: time_value(metrics["last_activity_at"])
        }
      end
    end

    def build_totals(rows)
      {
        tenants_count: rows.size,
        active_tenants_count: rows.count { |row| row[:tenant_active] },
        users_count: rows.sum { |row| row[:users_count] },
        hospitals_count: rows.sum { |row| row[:hospital_count] },
        hospital_organizations_count: rows.sum { |row| row[:hospital_organization_count] },
        receivables_count: rows.sum { |row| row[:receivable_count] },
        receivables_gross_amount: rows.sum(BigDecimal("0")) { |row| row[:receivable_gross_amount] },
        anticipations_count: rows.sum { |row| row[:anticipation_count] },
        anticipations_requested_amount: rows.sum(BigDecimal("0")) { |row| row[:anticipation_requested_amount] },
        settlements_count: rows.sum { |row| row[:settlement_count] },
        settlements_paid_amount: rows.sum(BigDecimal("0")) { |row| row[:settlement_paid_amount] },
        outbox_pending_count: rows.sum { |row| row[:outbox_pending_count] },
        outbox_dead_letter_count: rows.sum { |row| row[:outbox_dead_letter_count] },
        reconciliation_open_count: rows.sum { |row| row[:reconciliation_open_count] },
        reconciliation_total_count: rows.sum { |row| row[:reconciliation_total_count] },
        direct_upload_count: rows.sum { |row| row[:direct_upload_count] },
        last_activity_at: rows.map { |row| row[:last_activity_at] }.compact.max
      }
    end

    def build_recent_reconciliation_exceptions(tenants:, global_limit: 20, per_tenant_limit: 10)
      rows = tenants.flat_map do |tenant|
        with_tenant_database_context(tenant_id: tenant.id, actor_id: actor_id, role: role) do
          ReconciliationException
            .where(tenant_id: tenant.id, status: "OPEN")
            .order(last_seen_at: :desc)
            .limit(per_tenant_limit)
            .map do |exception|
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
        end
      end

      rows
        .sort_by { |row| row[:last_seen_at] || Time.at(0) }
        .reverse
        .first(global_limit)
    end

    def tenant_metrics(tenant_id:)
      quoted_tenant_id = ActiveRecord::Base.connection.quote(tenant_id)

      ActiveRecord::Base.connection.select_one(<<~SQL.squish)
        SELECT
          (SELECT COUNT(*) FROM users WHERE tenant_id = #{quoted_tenant_id}) AS users_count,
          (SELECT COUNT(*) FROM parties WHERE tenant_id = #{quoted_tenant_id} AND kind = 'HOSPITAL') AS hospital_count,
          (SELECT COUNT(DISTINCT organization_party_id) FROM hospital_ownerships WHERE tenant_id = #{quoted_tenant_id} AND active = TRUE) AS hospital_organization_count,
          (SELECT COUNT(*) FROM hospital_ownerships WHERE tenant_id = #{quoted_tenant_id} AND active = TRUE) AS hospital_ownership_count,
          (SELECT COUNT(*) FROM receivables WHERE tenant_id = #{quoted_tenant_id}) AS receivable_count,
          (SELECT COALESCE(SUM(gross_amount), 0) FROM receivables WHERE tenant_id = #{quoted_tenant_id}) AS receivable_gross_amount,
          (SELECT COUNT(*) FROM anticipation_requests WHERE tenant_id = #{quoted_tenant_id}) AS anticipation_count,
          (SELECT COALESCE(SUM(requested_amount), 0) FROM anticipation_requests WHERE tenant_id = #{quoted_tenant_id}) AS anticipation_requested_amount,
          (SELECT COUNT(*) FROM anticipation_requests WHERE tenant_id = #{quoted_tenant_id} AND status IN ('APPROVED', 'FUNDED', 'SETTLED')) AS funded_anticipation_count,
          (SELECT COUNT(*) FROM receivable_payment_settlements WHERE tenant_id = #{quoted_tenant_id}) AS settlement_count,
          (SELECT COALESCE(SUM(paid_amount), 0) FROM receivable_payment_settlements WHERE tenant_id = #{quoted_tenant_id}) AS settlement_paid_amount,
          (
            SELECT COUNT(*)
            FROM outbox_events events
            WHERE events.tenant_id = #{quoted_tenant_id}
              AND NOT EXISTS (
                SELECT 1
                FROM outbox_dispatch_attempts attempts
                WHERE attempts.tenant_id = events.tenant_id
                  AND attempts.outbox_event_id = events.id
                  AND attempts.status IN ('SENT', 'DEAD_LETTER')
              )
          ) AS outbox_pending_count,
          (SELECT COUNT(*) FROM outbox_dispatch_attempts WHERE tenant_id = #{quoted_tenant_id} AND status = 'DEAD_LETTER') AS outbox_dead_letter_count,
          (SELECT COUNT(*) FROM reconciliation_exceptions WHERE tenant_id = #{quoted_tenant_id} AND status = 'OPEN') AS reconciliation_open_count,
          (SELECT COUNT(*) FROM reconciliation_exceptions WHERE tenant_id = #{quoted_tenant_id}) AS reconciliation_total_count,
          (SELECT COUNT(*) FROM active_storage_blobs WHERE app_active_storage_blob_tenant_id(metadata) = CAST(#{quoted_tenant_id} AS uuid)) AS direct_upload_count,
          (
            SELECT GREATEST(
              COALESCE((SELECT MAX(updated_at) FROM receivables WHERE tenant_id = #{quoted_tenant_id}), 'epoch'::timestamp),
              COALESCE((SELECT MAX(updated_at) FROM anticipation_requests WHERE tenant_id = #{quoted_tenant_id}), 'epoch'::timestamp),
              COALESCE((SELECT MAX(updated_at) FROM receivable_payment_settlements WHERE tenant_id = #{quoted_tenant_id}), 'epoch'::timestamp),
              COALESCE((SELECT MAX(last_seen_at) FROM reconciliation_exceptions WHERE tenant_id = #{quoted_tenant_id}), 'epoch'::timestamp),
              COALESCE((SELECT MAX(occurred_at) FROM action_ip_logs WHERE tenant_id = #{quoted_tenant_id}), 'epoch'::timestamp)
            )
          ) AS last_activity_at
      SQL
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
