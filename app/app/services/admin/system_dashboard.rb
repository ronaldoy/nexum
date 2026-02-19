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
        receivables_scope = Receivable.where(tenant_id: tenant.id)
        anticipation_scope = AnticipationRequest.where(tenant_id: tenant.id)
        settlements_scope = ReceivablePaymentSettlement.where(tenant_id: tenant.id)
        ownerships_scope = HospitalOwnership.where(tenant_id: tenant.id, active: true)
        outbox_scope = OutboxEvent.where(tenant_id: tenant.id)
        dispatch_attempts_scope = OutboxDispatchAttempt.where(tenant_id: tenant.id)
        reconciliation_scope = ReconciliationException.where(tenant_id: tenant.id)
        reconciliation_open_scope = reconciliation_scope.open
        sent_outbox_ids = dispatch_attempts_scope.where(status: "SENT").select(:outbox_event_id)
        dead_letter_outbox_ids = dispatch_attempts_scope.where(status: "DEAD_LETTER").select(:outbox_event_id)

        {
          tenant_id: tenant.id,
          tenant_slug: tenant.slug,
          tenant_name: tenant.name,
          tenant_active: tenant.active,
          users_count: User.where(tenant_id: tenant.id).count,
          hospital_count: Party.where(tenant_id: tenant.id, kind: "HOSPITAL").count,
          hospital_organization_count: ownerships_scope.select(:organization_party_id).distinct.count,
          hospital_ownership_count: ownerships_scope.count,
          receivable_count: receivables_scope.count,
          receivable_gross_amount: receivables_scope.sum(:gross_amount).to_d,
          anticipation_count: anticipation_scope.count,
          anticipation_requested_amount: anticipation_scope.sum(:requested_amount).to_d,
          funded_anticipation_count: anticipation_scope.where(status: %w[APPROVED FUNDED SETTLED]).count,
          settlement_count: settlements_scope.count,
          settlement_paid_amount: settlements_scope.sum(:paid_amount).to_d,
          outbox_pending_count: outbox_scope.where.not(id: sent_outbox_ids).where.not(id: dead_letter_outbox_ids).count,
          outbox_dead_letter_count: dispatch_attempts_scope.where(status: "DEAD_LETTER").count,
          reconciliation_open_count: reconciliation_open_scope.count,
          reconciliation_total_count: reconciliation_scope.count,
          direct_upload_count: ActiveStorage::Blob.where(
            "app_active_storage_blob_tenant_id(metadata) = CAST(? AS uuid)",
            tenant.id
          ).count,
          last_activity_at: [
            receivables_scope.maximum(:updated_at),
            anticipation_scope.maximum(:updated_at),
            settlements_scope.maximum(:updated_at),
            reconciliation_scope.maximum(:last_seen_at),
            ActionIpLog.where(tenant_id: tenant.id).maximum(:occurred_at)
          ].compact.max
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
