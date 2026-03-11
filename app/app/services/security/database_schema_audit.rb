module Security
  class DatabaseSchemaAudit
    VIOLATION_MESSAGE = "Database schema security violation".freeze
    INTERNAL_TABLES = %w[ar_internal_metadata schema_migrations].freeze
    REQUIRED_APPEND_ONLY_TABLES = %w[
      action_ip_logs
      anticipation_risk_decisions
      anticipation_risk_rule_events
      anticipation_request_events
      anticipation_settlement_entries
      document_events
      kyc_events
      ledger_entries
      ledger_transactions
      outbox_dispatch_attempts
      outbox_events
      provider_webhook_receipts
      receivable_events
      receivable_payment_settlements
    ].freeze
    REQUIRED_VALIDATED_CONSTRAINTS = %w[
      fk_action_ip_logs_tenant_actor_party
      anticipation_requests_discount_rounding_check
      anticipation_requests_idempotency_key_present_check
      anticipation_requests_net_amount_breakdown_check
      fk_anticipation_requests_tenant_receivable
      fk_anticipation_requests_tenant_receivable_allocation
      fk_anticipation_requests_tenant_requester_party
      auth_challenges_attempts_lte_max_check
      auth_challenges_code_digest_format_check
      auth_challenges_destination_masked_present_check
      auth_challenges_purpose_present_check
      auth_challenges_target_type_present_check
      fk_auth_challenges_tenant_actor_party
      fk_document_events_tenant_actor_party
      fk_document_events_tenant_document
      fk_document_events_tenant_receivable
      documents_admin_import_metadata_check
      documents_own_platform_confirmation_metadata_check
      documents_sha256_format_check
      documents_signature_method_check
      documents_storage_key_present_check
      fk_documents_tenant_actor_party
      fk_documents_tenant_receivable
      fk_ledger_entries_tenant_party
      fk_ledger_entries_tenant_receivable
      fk_ledger_transactions_tenant_actor_party
      fk_ledger_transactions_tenant_receivable
      provider_webhook_receipts_failed_error_details_check
      fk_receivable_events_tenant_actor_party
      fk_receivable_events_tenant_receivable
      fk_receivable_payment_settlements_tenant_receivable
      fk_receivable_payment_settlements_tenant_receivable_allocation
    ].freeze
    REQUIRED_UNIQUE_INDEX = "idx_auth_challenges_active_uniqueness_lookup".freeze

    class << self
      def ensure_secure!(connection: ActiveRecord::Base.connection)
        violations = violations(connection:)
        return true if violations.empty?

        raise "#{VIOLATION_MESSAGE}: #{violations.join('; ')}"
      end

      def readiness_status(connection: ActiveRecord::Base.connection)
        secure?(connection:) ? "ok" : "error"
      rescue PG::Error, ActiveRecord::ActiveRecordError => error
        Rails.logger.error("database_schema_security_check_failed error_class=#{error.class} message=#{error.message}")
        "error"
      end

      def secure?(connection: ActiveRecord::Base.connection)
        violations(connection:).empty?
      end

      def violations(connection: ActiveRecord::Base.connection)
        violations = []

        missing_rls = tenant_scoped_tables(connection:) - tables_with_forced_rls(connection:)
        violations << "tables missing FORCE RLS: #{missing_rls.join(', ')}" if missing_rls.any?

        missing_append_only = REQUIRED_APPEND_ONLY_TABLES - append_only_tables(connection:)
        violations << "tables missing append-only trigger: #{missing_append_only.join(', ')}" if missing_append_only.any?

        unvalidated_constraints = required_constraint_rows(connection:).reject { |row| boolean_cast(row.fetch("convalidated", false)) }
        if unvalidated_constraints.any?
          violations << "constraints not validated: #{unvalidated_constraints.map { |row| row.fetch('conname') }.join(', ')}"
        end

        missing_constraints = REQUIRED_VALIDATED_CONSTRAINTS - required_constraint_rows(connection:).map { |row| row.fetch("conname") }
        violations << "required constraints missing: #{missing_constraints.join(', ')}" if missing_constraints.any?

        violations << "active auth challenge unique index missing or not unique" unless auth_challenge_unique_index_secure?(connection:)

        violations
      end

      def tenant_scoped_tables(connection: ActiveRecord::Base.connection)
        connection.select_values(<<~SQL)
          SELECT DISTINCT c.table_name
          FROM information_schema.columns c
          INNER JOIN information_schema.tables t
            ON t.table_schema = c.table_schema
           AND t.table_name = c.table_name
          WHERE c.table_schema = 'public'
            AND c.column_name = 'tenant_id'
            AND t.table_type = 'BASE TABLE'
            AND c.table_name NOT IN (#{quoted_internal_tables(connection)})
          ORDER BY c.table_name
        SQL
      end

      def tables_with_forced_rls(connection: ActiveRecord::Base.connection)
        connection.select_values(<<~SQL)
          SELECT relname
          FROM pg_class
          WHERE relnamespace = 'public'::regnamespace
            AND relkind IN ('r', 'p')
            AND relrowsecurity = true
            AND relforcerowsecurity = true
        SQL
      end

      def append_only_tables(connection: ActiveRecord::Base.connection)
        connection.select_values(<<~SQL)
          SELECT c.relname
          FROM pg_trigger t
          INNER JOIN pg_class c ON c.oid = t.tgrelid
          INNER JOIN pg_proc p ON p.oid = t.tgfoid
          INNER JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public'
            AND t.tgisinternal = false
            AND t.tgname LIKE '%\\_no_update_delete'
            AND p.proname = 'app_forbid_mutation'
          ORDER BY c.relname
        SQL
      end

      def required_constraint_rows(connection: ActiveRecord::Base.connection)
        connection.select_all(<<~SQL).to_a
          SELECT conname, convalidated
          FROM pg_constraint
          WHERE connamespace = 'public'::regnamespace
            AND conname IN (#{quoted_required_constraints(connection)})
        SQL
      end

      def auth_challenge_unique_index_secure?(connection: ActiveRecord::Base.connection)
        row = connection.select_one(<<~SQL)
          SELECT idx.indisunique, pg_get_expr(idx.indpred, idx.indrelid) AS predicate
          FROM pg_index idx
          INNER JOIN pg_class index_class ON index_class.oid = idx.indexrelid
          INNER JOIN pg_class table_class ON table_class.oid = idx.indrelid
          WHERE table_class.relnamespace = 'public'::regnamespace
            AND table_class.relname = 'auth_challenges'
            AND index_class.relname = #{connection.quote(REQUIRED_UNIQUE_INDEX)}
          LIMIT 1
        SQL

        return false if row.blank?

        boolean_cast(row.fetch("indisunique", false)) &&
          row.fetch("predicate", "").include?("consumed_at IS NULL") &&
          row.fetch("predicate", "").include?("PENDING") &&
          row.fetch("predicate", "").include?("VERIFIED")
      end

      private

      def quoted_internal_tables(connection)
        INTERNAL_TABLES.map { |name| connection.quote(name) }.join(", ")
      end

      def quoted_required_constraints(connection)
        REQUIRED_VALIDATED_CONSTRAINTS.map { |name| connection.quote(name) }.join(", ")
      end

      def boolean_cast(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end
    end
  end
end
