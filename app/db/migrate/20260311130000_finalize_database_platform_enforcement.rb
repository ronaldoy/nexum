class FinalizeDatabasePlatformEnforcement < ActiveRecord::Migration[8.2]
  AUTH_CHALLENGE_ACTIVE_INDEX_NAME = "idx_auth_challenges_active_uniqueness_lookup".freeze
  AUTH_CHALLENGE_ACTIVE_INDEX_COLUMNS = %i[
    tenant_id
    actor_party_id
    purpose
    delivery_channel
    target_type
    target_id
  ].freeze
  AUTH_CHALLENGE_ACTIVE_INDEX_WHERE = "consumed_at IS NULL AND status IN ('PENDING', 'VERIFIED')".freeze
  AUTH_CHALLENGE_CODE_DIGEST_PATTERN = "^(hmac-sha256-v1\\$)?[0-9a-f]{64}$".freeze

  VALIDATABLE_CONSTRAINTS = {
    action_ip_logs: %w[
      fk_action_ip_logs_tenant_actor_party
    ],
    anticipation_requests: %w[
      anticipation_requests_discount_rounding_check
      anticipation_requests_idempotency_key_present_check
      anticipation_requests_net_amount_breakdown_check
      fk_anticipation_requests_tenant_receivable
      fk_anticipation_requests_tenant_receivable_allocation
      fk_anticipation_requests_tenant_requester_party
    ],
    auth_challenges: %w[
      auth_challenges_attempts_lte_max_check
      auth_challenges_code_digest_format_check
      auth_challenges_destination_masked_present_check
      auth_challenges_purpose_present_check
      auth_challenges_target_type_present_check
      fk_auth_challenges_tenant_actor_party
    ],
    document_events: %w[
      fk_document_events_tenant_actor_party
      fk_document_events_tenant_document
      fk_document_events_tenant_receivable
    ],
    documents: %w[
      documents_admin_import_metadata_check
      documents_own_platform_confirmation_metadata_check
      documents_sha256_format_check
      documents_signature_method_check
      documents_storage_key_present_check
      fk_documents_tenant_actor_party
      fk_documents_tenant_receivable
    ],
    ledger_entries: %w[
      fk_ledger_entries_tenant_party
      fk_ledger_entries_tenant_receivable
    ],
    ledger_transactions: %w[
      fk_ledger_transactions_tenant_actor_party
      fk_ledger_transactions_tenant_receivable
    ],
    provider_webhook_receipts: %w[
      provider_webhook_receipts_failed_error_details_check
    ],
    receivable_events: %w[
      fk_receivable_events_tenant_actor_party
      fk_receivable_events_tenant_receivable
    ],
    receivable_payment_settlements: %w[
      fk_receivable_payment_settlements_tenant_receivable
      fk_receivable_payment_settlements_tenant_receivable_allocation
    ]
  }.freeze

  def up
    cleanup_legacy_action_ip_logs!
    cleanup_legacy_auth_challenges!
    cleanup_legacy_documents!
    enforce_active_auth_challenge_uniqueness_with_unique_index!
    validate_database_platform_constraints!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "This migration removes legacy pre-production data and finalizes database enforcement."
  end

  private

  def cleanup_legacy_action_ip_logs!
    with_append_only_trigger_disabled(:action_ip_logs, "action_ip_logs_no_update_delete") do
      delete_with_count(<<~SQL, label: "Removing orphaned action_ip_logs rows")
        DELETE FROM public.action_ip_logs logs
        WHERE logs.actor_party_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM public.parties parent
            WHERE parent.tenant_id = logs.tenant_id
              AND parent.id = logs.actor_party_id
          )
      SQL
    end
  end

  def cleanup_legacy_auth_challenges!
    with_auth_challenge_mutation_trigger_disabled do
      delete_with_count(<<~SQL, label: "Removing invalid auth_challenges rows")
        DELETE FROM public.auth_challenges challenges
        WHERE challenges.attempts > challenges.max_attempts
           OR NULLIF(btrim(challenges.purpose), '') IS NULL
           OR NULLIF(btrim(challenges.destination_masked), '') IS NULL
           OR NULLIF(btrim(challenges.target_type), '') IS NULL
           OR challenges.code_digest !~ #{connection.quote(AUTH_CHALLENGE_CODE_DIGEST_PATTERN)}
      SQL

      delete_with_count(<<~SQL, label: "Removing duplicate active auth_challenges rows")
        WITH ranked AS (
          SELECT
            id,
            ROW_NUMBER() OVER (
              PARTITION BY tenant_id, actor_party_id, purpose, delivery_channel, target_type, target_id
              ORDER BY created_at DESC, id DESC
            ) AS row_number
          FROM public.auth_challenges
          WHERE consumed_at IS NULL
            AND status IN ('PENDING', 'VERIFIED')
        )
        DELETE FROM public.auth_challenges
        WHERE id IN (
          SELECT id
          FROM ranked
          WHERE row_number > 1
        )
      SQL
    end
  end

  def cleanup_legacy_documents!
    with_append_only_trigger_disabled(:document_events, "document_events_no_update_delete") do
      with_document_mutation_trigger_disabled do
        delete_with_count(<<~SQL, label: "Removing legacy document_events rows tied to invalid documents")
          DELETE FROM public.document_events events
          WHERE events.document_id IN (
            #{invalid_documents_scope_sql}
          )
        SQL

        delete_with_count(<<~SQL, label: "Removing invalid legacy documents")
          DELETE FROM public.documents
          WHERE id IN (
            #{invalid_documents_scope_sql}
          )
        SQL
      end
    end
  end

  def enforce_active_auth_challenge_uniqueness_with_unique_index!
    existing_index = connection.indexes(:auth_challenges).find { |index| index.name == AUTH_CHALLENGE_ACTIVE_INDEX_NAME }
    return if existing_index&.unique

    remove_index :auth_challenges, name: AUTH_CHALLENGE_ACTIVE_INDEX_NAME if existing_index.present?
    add_index(
      :auth_challenges,
      AUTH_CHALLENGE_ACTIVE_INDEX_COLUMNS,
      unique: true,
      name: AUTH_CHALLENGE_ACTIVE_INDEX_NAME,
      where: AUTH_CHALLENGE_ACTIVE_INDEX_WHERE
    )
  end

  def validate_database_platform_constraints!
    VALIDATABLE_CONSTRAINTS.each do |table_name, constraint_names|
      constraint_names.each do |constraint_name|
        validate_constraint_if_needed!(table_name, constraint_name)
      end
    end
  end

  def invalid_documents_scope_sql
    <<~SQL.squish
      SELECT id
      FROM public.documents
      WHERE signature_method NOT IN ('OWN_PLATFORM_CONFIRMATION', 'ADMIN_IMPORTED_EVIDENCE')
         OR sha256 !~ '^[0-9a-f]{64}$'
         OR btrim(storage_key) = ''
         OR (
           signature_method = 'OWN_PLATFORM_CONFIRMATION'
           AND (
             NULLIF(btrim(COALESCE(metadata ->> 'provider_envelope_id', '')), '') IS NULL
             OR NULLIF(btrim(COALESCE(metadata ->> 'email_challenge_id', '')), '') IS NULL
             OR NULLIF(btrim(COALESCE(metadata ->> 'whatsapp_challenge_id', '')), '') IS NULL
           )
         )
         OR (
           signature_method = 'ADMIN_IMPORTED_EVIDENCE'
           AND NULLIF(btrim(COALESCE(metadata ->> 'imported_by_party_id', '')), '') IS NULL
         )
    SQL
  end

  def delete_with_count(delete_sql, label:)
    deleted_count = select_delete_count(delete_sql)
    say("#{label}: #{deleted_count}") if deleted_count.positive?
  end

  def select_delete_count(delete_sql)
    connection.select_value(<<~SQL).to_i
      WITH deleted_rows AS (
        #{delete_sql}
        RETURNING 1
      )
      SELECT COUNT(*)
      FROM deleted_rows
    SQL
  end

  def validate_constraint_if_needed!(table_name, constraint_name)
    result = connection.select_one(<<~SQL)
      SELECT convalidated
      FROM pg_constraint
      WHERE conname = #{connection.quote(constraint_name)}
        AND conrelid = to_regclass(#{connection.quote("public.#{table_name}")})
      LIMIT 1
    SQL

    return if result.blank? || result["convalidated"]

    execute("ALTER TABLE public.#{table_name} VALIDATE CONSTRAINT #{constraint_name}")
  end

  def with_append_only_trigger_disabled(table_name, trigger_name)
    execute("DROP TRIGGER IF EXISTS #{trigger_name} ON public.#{table_name}")
    yield
  ensure
    execute <<~SQL
      CREATE TRIGGER #{trigger_name}
      BEFORE DELETE OR UPDATE ON public.#{table_name}
      FOR EACH ROW
      EXECUTE FUNCTION public.app_forbid_mutation();
    SQL
  end

  def with_document_mutation_trigger_disabled
    execute "DROP TRIGGER IF EXISTS documents_protect_mutation ON public.documents"
    yield
  ensure
    execute <<~SQL
      CREATE TRIGGER documents_protect_mutation
      BEFORE DELETE OR UPDATE ON public.documents
      FOR EACH ROW
      EXECUTE FUNCTION public.app_protect_documents();
    SQL
  end

  def with_auth_challenge_mutation_trigger_disabled
    execute "DROP TRIGGER IF EXISTS auth_challenges_protect_mutation ON public.auth_challenges"
    yield
  ensure
    execute <<~SQL
      CREATE TRIGGER auth_challenges_protect_mutation
      BEFORE DELETE OR UPDATE ON public.auth_challenges
      FOR EACH ROW
      EXECUTE FUNCTION public.app_protect_auth_challenges();
    SQL
  end
end
