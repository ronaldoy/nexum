class HardenDatabasePlatformEnforcement < ActiveRecord::Migration[8.2]
  PARENT_IDENTITY_INDEXES = [
    {
      table: :parties,
      columns: %i[tenant_id id],
      name: "idx_parties_tenant_id_id"
    },
    {
      table: :receivables,
      columns: %i[tenant_id id],
      name: "idx_receivables_tenant_id_id"
    },
    {
      table: :receivable_allocations,
      columns: %i[tenant_id id],
      name: "idx_receivable_allocations_tenant_id_id"
    },
    {
      table: :documents,
      columns: %i[tenant_id id],
      name: "idx_documents_tenant_id_id"
    }
  ].freeze

  COMPOSITE_FOREIGN_KEYS = [
    {
      table: :action_ip_logs,
      name: "fk_action_ip_logs_tenant_actor_party",
      columns: %i[tenant_id actor_party_id],
      references: :parties
    },
    {
      table: :auth_challenges,
      name: "fk_auth_challenges_tenant_actor_party",
      columns: %i[tenant_id actor_party_id],
      references: :parties
    },
    {
      table: :documents,
      name: "fk_documents_tenant_receivable",
      columns: %i[tenant_id receivable_id],
      references: :receivables
    },
    {
      table: :documents,
      name: "fk_documents_tenant_actor_party",
      columns: %i[tenant_id actor_party_id],
      references: :parties
    },
    {
      table: :document_events,
      name: "fk_document_events_tenant_document",
      columns: %i[tenant_id document_id],
      references: :documents
    },
    {
      table: :document_events,
      name: "fk_document_events_tenant_receivable",
      columns: %i[tenant_id receivable_id],
      references: :receivables
    },
    {
      table: :document_events,
      name: "fk_document_events_tenant_actor_party",
      columns: %i[tenant_id actor_party_id],
      references: :parties
    },
    {
      table: :anticipation_requests,
      name: "fk_anticipation_requests_tenant_receivable_allocation",
      columns: %i[tenant_id receivable_allocation_id],
      references: :receivable_allocations
    },
    {
      table: :anticipation_requests,
      name: "fk_anticipation_requests_tenant_receivable",
      columns: %i[tenant_id receivable_id],
      references: :receivables
    },
    {
      table: :anticipation_requests,
      name: "fk_anticipation_requests_tenant_requester_party",
      columns: %i[tenant_id requester_party_id],
      references: :parties
    },
    {
      table: :ledger_transactions,
      name: "fk_ledger_transactions_tenant_receivable",
      columns: %i[tenant_id receivable_id],
      references: :receivables
    },
    {
      table: :ledger_transactions,
      name: "fk_ledger_transactions_tenant_actor_party",
      columns: %i[tenant_id actor_party_id],
      references: :parties
    },
    {
      table: :ledger_entries,
      name: "fk_ledger_entries_tenant_receivable",
      columns: %i[tenant_id receivable_id],
      references: :receivables
    },
    {
      table: :ledger_entries,
      name: "fk_ledger_entries_tenant_party",
      columns: %i[tenant_id party_id],
      references: :parties
    },
    {
      table: :receivable_events,
      name: "fk_receivable_events_tenant_receivable",
      columns: %i[tenant_id receivable_id],
      references: :receivables
    },
    {
      table: :receivable_events,
      name: "fk_receivable_events_tenant_actor_party",
      columns: %i[tenant_id actor_party_id],
      references: :parties
    },
    {
      table: :receivable_payment_settlements,
      name: "fk_receivable_payment_settlements_tenant_receivable",
      columns: %i[tenant_id receivable_id],
      references: :receivables
    },
    {
      table: :receivable_payment_settlements,
      name: "fk_receivable_payment_settlements_tenant_receivable_allocation",
      columns: %i[tenant_id receivable_allocation_id],
      references: :receivable_allocations
    }
  ].freeze

  def up
    add_parent_identity_indexes!
    install_document_protection!
    install_auth_challenge_protection!
    install_provider_webhook_receipt_append_only_trigger!
    add_document_constraints!
    add_auth_challenge_constraints!
    add_anticipation_request_constraints!
    add_provider_webhook_receipt_constraints!
    add_auth_challenge_lookup_index!
    add_composite_foreign_keys!
  end

  def down
    remove_composite_foreign_keys!
    remove_auth_challenge_lookup_index!
    remove_provider_webhook_receipt_constraints!
    remove_anticipation_request_constraints!
    remove_auth_challenge_constraints!
    remove_document_constraints!
    remove_provider_webhook_receipt_append_only_trigger!
    remove_auth_challenge_protection!
    remove_document_protection!
    remove_parent_identity_indexes!
  end

  private

  def add_parent_identity_indexes!
    PARENT_IDENTITY_INDEXES.each do |definition|
      next if index_exists?(definition[:table], definition[:columns], name: definition[:name])

      add_index definition[:table], definition[:columns], unique: true, name: definition[:name]
    end
  end

  def remove_parent_identity_indexes!
    PARENT_IDENTITY_INDEXES.reverse_each do |definition|
      next unless index_exists?(definition[:table], definition[:columns], name: definition[:name])

      remove_index definition[:table], name: definition[:name]
    end
  end

  def install_document_protection!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION public.app_protect_documents() RETURNS trigger
          LANGUAGE plpgsql
          AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'DELETE not allowed on documents';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          IF NEW.id IS DISTINCT FROM OLD.id
            OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
            OR NEW.receivable_id IS DISTINCT FROM OLD.receivable_id
            OR NEW.actor_party_id IS DISTINCT FROM OLD.actor_party_id
            OR NEW.document_type IS DISTINCT FROM OLD.document_type
            OR NEW.signature_method IS DISTINCT FROM OLD.signature_method
            OR NEW.status IS DISTINCT FROM OLD.status
            OR NEW.sha256 IS DISTINCT FROM OLD.sha256
            OR NEW.storage_key IS DISTINCT FROM OLD.storage_key
            OR NEW.signed_at IS DISTINCT FROM OLD.signed_at
            OR NEW.metadata IS DISTINCT FROM OLD.metadata
            OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'Only updated_at can change on documents';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute "DROP TRIGGER IF EXISTS documents_protect_mutation ON public.documents"
    execute <<~SQL
      CREATE TRIGGER documents_protect_mutation
      BEFORE DELETE OR UPDATE ON public.documents
      FOR EACH ROW
      EXECUTE FUNCTION public.app_protect_documents();
    SQL
  end

  def remove_document_protection!
    execute "DROP TRIGGER IF EXISTS documents_protect_mutation ON public.documents"
    execute "DROP FUNCTION IF EXISTS public.app_protect_documents()"
  end

  def install_auth_challenge_protection!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION public.app_protect_auth_challenges() RETURNS trigger
          LANGUAGE plpgsql
          AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'DELETE not allowed on auth_challenges';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          IF NEW.id IS DISTINCT FROM OLD.id
            OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
            OR NEW.actor_party_id IS DISTINCT FROM OLD.actor_party_id
            OR NEW.purpose IS DISTINCT FROM OLD.purpose
            OR NEW.delivery_channel IS DISTINCT FROM OLD.delivery_channel
            OR NEW.destination_masked IS DISTINCT FROM OLD.destination_masked
            OR NEW.code_digest IS DISTINCT FROM OLD.code_digest
            OR NEW.max_attempts IS DISTINCT FROM OLD.max_attempts
            OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
            OR NEW.request_id IS DISTINCT FROM OLD.request_id
            OR NEW.target_type IS DISTINCT FROM OLD.target_type
            OR NEW.target_id IS DISTINCT FROM OLD.target_id
            OR NEW.metadata IS DISTINCT FROM OLD.metadata
            OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'Only status, attempts, consumed_at, and updated_at can change on auth_challenges';
          END IF;

          IF NEW.attempts < OLD.attempts OR NEW.attempts > OLD.attempts + 1 THEN
            RAISE EXCEPTION 'auth_challenges attempts can only stay the same or increment by 1';
          END IF;

          IF NEW.attempts > NEW.max_attempts THEN
            RAISE EXCEPTION 'auth_challenges attempts cannot exceed max_attempts';
          END IF;

          IF OLD.consumed_at IS NOT NULL AND NEW.consumed_at IS DISTINCT FROM OLD.consumed_at THEN
            RAISE EXCEPTION 'auth_challenges consumed_at cannot change once set';
          END IF;

          IF NEW.status = 'PENDING' AND NEW.consumed_at IS NOT NULL THEN
            RAISE EXCEPTION 'auth_challenges consumed_at must be null while status is PENDING';
          END IF;

          IF NOT (
            (OLD.status = 'PENDING' AND NEW.status IN ('PENDING', 'VERIFIED', 'EXPIRED', 'CANCELLED')) OR
            (OLD.status = 'VERIFIED' AND NEW.status IN ('VERIFIED', 'CANCELLED')) OR
            (OLD.status = 'EXPIRED' AND NEW.status = 'EXPIRED') OR
            (OLD.status = 'CANCELLED' AND NEW.status = 'CANCELLED')
          ) THEN
            RAISE EXCEPTION 'Invalid auth_challenges status transition from % to %', OLD.status, NEW.status;
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION public.app_enforce_active_auth_challenge_uniqueness() RETURNS trigger
          LANGUAGE plpgsql
          AS $$
      BEGIN
        IF NEW.consumed_at IS NULL AND NEW.status IN ('PENDING', 'VERIFIED') THEN
          PERFORM 1
          FROM public.auth_challenges existing
          WHERE existing.tenant_id = NEW.tenant_id
            AND existing.actor_party_id = NEW.actor_party_id
            AND existing.purpose = NEW.purpose
            AND existing.delivery_channel = NEW.delivery_channel
            AND existing.target_type = NEW.target_type
            AND existing.target_id = NEW.target_id
            AND existing.consumed_at IS NULL
            AND existing.status IN ('PENDING', 'VERIFIED')
            AND existing.id <> NEW.id
          LIMIT 1;

          IF FOUND THEN
            RAISE EXCEPTION 'Active auth_challenge already exists for tenant %, actor %, purpose %, channel %, target %/%',
              NEW.tenant_id, NEW.actor_party_id, NEW.purpose, NEW.delivery_channel, NEW.target_type, NEW.target_id;
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute "DROP TRIGGER IF EXISTS auth_challenges_protect_mutation ON public.auth_challenges"
    execute <<~SQL
      CREATE TRIGGER auth_challenges_protect_mutation
      BEFORE DELETE OR UPDATE ON public.auth_challenges
      FOR EACH ROW
      EXECUTE FUNCTION public.app_protect_auth_challenges();
    SQL

    execute "DROP TRIGGER IF EXISTS auth_challenges_active_uniqueness ON public.auth_challenges"
    execute <<~SQL
      CREATE TRIGGER auth_challenges_active_uniqueness
      BEFORE INSERT OR UPDATE ON public.auth_challenges
      FOR EACH ROW
      EXECUTE FUNCTION public.app_enforce_active_auth_challenge_uniqueness();
    SQL
  end

  def remove_auth_challenge_protection!
    execute "DROP TRIGGER IF EXISTS auth_challenges_active_uniqueness ON public.auth_challenges"
    execute "DROP TRIGGER IF EXISTS auth_challenges_protect_mutation ON public.auth_challenges"
    execute "DROP FUNCTION IF EXISTS public.app_enforce_active_auth_challenge_uniqueness()"
    execute "DROP FUNCTION IF EXISTS public.app_protect_auth_challenges()"
  end

  def install_provider_webhook_receipt_append_only_trigger!
    execute "DROP TRIGGER IF EXISTS provider_webhook_receipts_no_update_delete ON public.provider_webhook_receipts"
    execute <<~SQL
      CREATE TRIGGER provider_webhook_receipts_no_update_delete
      BEFORE DELETE OR UPDATE ON public.provider_webhook_receipts
      FOR EACH ROW
      EXECUTE FUNCTION public.app_forbid_mutation();
    SQL
  end

  def remove_provider_webhook_receipt_append_only_trigger!
    execute "DROP TRIGGER IF EXISTS provider_webhook_receipts_no_update_delete ON public.provider_webhook_receipts"
  end

  def add_document_constraints!
    add_check_constraint_if_missing!(
      :documents,
      "signature_method IN ('OWN_PLATFORM_CONFIRMATION', 'ADMIN_IMPORTED_EVIDENCE')",
      name: "documents_signature_method_check"
    )
    add_check_constraint_if_missing!(
      :documents,
      "sha256 ~ '^[0-9a-f]{64}$'",
      name: "documents_sha256_format_check"
    )
    add_check_constraint_if_missing!(
      :documents,
      "btrim(storage_key) <> ''",
      name: "documents_storage_key_present_check"
    )
    add_check_constraint_if_missing!(
      :documents,
      <<~SQL.squish,
        signature_method <> 'OWN_PLATFORM_CONFIRMATION' OR (
          NULLIF(btrim(COALESCE(metadata ->> 'provider_envelope_id', '')), '') IS NOT NULL AND
          NULLIF(btrim(COALESCE(metadata ->> 'email_challenge_id', '')), '') IS NOT NULL AND
          NULLIF(btrim(COALESCE(metadata ->> 'whatsapp_challenge_id', '')), '') IS NOT NULL
        )
      SQL
      name: "documents_own_platform_confirmation_metadata_check"
    )
    add_check_constraint_if_missing!(
      :documents,
      <<~SQL.squish,
        signature_method <> 'ADMIN_IMPORTED_EVIDENCE' OR
          NULLIF(btrim(COALESCE(metadata ->> 'imported_by_party_id', '')), '') IS NOT NULL
      SQL
      name: "documents_admin_import_metadata_check"
    )
  end

  def remove_document_constraints!
    remove_check_constraint_if_exists!(:documents, "documents_admin_import_metadata_check")
    remove_check_constraint_if_exists!(:documents, "documents_own_platform_confirmation_metadata_check")
    remove_check_constraint_if_exists!(:documents, "documents_storage_key_present_check")
    remove_check_constraint_if_exists!(:documents, "documents_sha256_format_check")
    remove_check_constraint_if_exists!(:documents, "documents_signature_method_check")
  end

  def add_auth_challenge_constraints!
    add_check_constraint_if_missing!(
      :auth_challenges,
      "attempts <= max_attempts",
      name: "auth_challenges_attempts_lte_max_check"
    )
    add_check_constraint_if_missing!(
      :auth_challenges,
      "NULLIF(btrim(purpose), '') IS NOT NULL",
      name: "auth_challenges_purpose_present_check"
    )
    add_check_constraint_if_missing!(
      :auth_challenges,
      "NULLIF(btrim(destination_masked), '') IS NOT NULL",
      name: "auth_challenges_destination_masked_present_check"
    )
    add_check_constraint_if_missing!(
      :auth_challenges,
      "NULLIF(btrim(target_type), '') IS NOT NULL",
      name: "auth_challenges_target_type_present_check"
    )
    add_check_constraint_if_missing!(
      :auth_challenges,
      "code_digest ~ '^(hmac-sha256-v1\\$)?[0-9a-f]{64}$'",
      name: "auth_challenges_code_digest_format_check"
    )
  end

  def remove_auth_challenge_constraints!
    remove_check_constraint_if_exists!(:auth_challenges, "auth_challenges_code_digest_format_check")
    remove_check_constraint_if_exists!(:auth_challenges, "auth_challenges_target_type_present_check")
    remove_check_constraint_if_exists!(:auth_challenges, "auth_challenges_destination_masked_present_check")
    remove_check_constraint_if_exists!(:auth_challenges, "auth_challenges_purpose_present_check")
    remove_check_constraint_if_exists!(:auth_challenges, "auth_challenges_attempts_lte_max_check")
  end

  def add_anticipation_request_constraints!
    add_check_constraint_if_missing!(
      :anticipation_requests,
      "btrim(idempotency_key) <> ''",
      name: "anticipation_requests_idempotency_key_present_check"
    )
    add_check_constraint_if_missing!(
      :anticipation_requests,
      "discount_amount = CEIL((requested_amount * discount_rate) * 100) / 100",
      name: "anticipation_requests_discount_rounding_check"
    )
    add_check_constraint_if_missing!(
      :anticipation_requests,
      "net_amount = requested_amount - discount_amount",
      name: "anticipation_requests_net_amount_breakdown_check"
    )
  end

  def remove_anticipation_request_constraints!
    remove_check_constraint_if_exists!(:anticipation_requests, "anticipation_requests_net_amount_breakdown_check")
    remove_check_constraint_if_exists!(:anticipation_requests, "anticipation_requests_discount_rounding_check")
    remove_check_constraint_if_exists!(:anticipation_requests, "anticipation_requests_idempotency_key_present_check")
  end

  def add_provider_webhook_receipt_constraints!
    add_check_constraint_if_missing!(
      :provider_webhook_receipts,
      <<~SQL.squish,
        status <> 'FAILED' OR (
          NULLIF(btrim(COALESCE(error_code, '')), '') IS NOT NULL AND
          NULLIF(btrim(COALESCE(error_message, '')), '') IS NOT NULL
        )
      SQL
      name: "provider_webhook_receipts_failed_error_details_check"
    )
  end

  def remove_provider_webhook_receipt_constraints!
    remove_check_constraint_if_exists!(:provider_webhook_receipts, "provider_webhook_receipts_failed_error_details_check")
  end

  def add_auth_challenge_lookup_index!
    return if index_exists?(
      :auth_challenges,
      %i[tenant_id actor_party_id purpose delivery_channel target_type target_id],
      name: "idx_auth_challenges_active_uniqueness_lookup"
    )

    add_index(
      :auth_challenges,
      %i[tenant_id actor_party_id purpose delivery_channel target_type target_id],
      name: "idx_auth_challenges_active_uniqueness_lookup",
      where: "consumed_at IS NULL AND status IN ('PENDING', 'VERIFIED')"
    )
  end

  def remove_auth_challenge_lookup_index!
    return unless index_exists?(
      :auth_challenges,
      %i[tenant_id actor_party_id purpose delivery_channel target_type target_id],
      name: "idx_auth_challenges_active_uniqueness_lookup"
    )

    remove_index :auth_challenges, name: "idx_auth_challenges_active_uniqueness_lookup"
  end

  def add_composite_foreign_keys!
    COMPOSITE_FOREIGN_KEYS.each do |definition|
      next if constraint_exists?(definition[:table], definition[:name])

      execute <<~SQL
        ALTER TABLE #{definition[:table]}
        ADD CONSTRAINT #{definition[:name]}
        FOREIGN KEY (#{definition[:columns].join(', ')})
        REFERENCES #{definition[:references]}(tenant_id, id)
        NOT VALID
      SQL
    end
  end

  def remove_composite_foreign_keys!
    COMPOSITE_FOREIGN_KEYS.reverse_each do |definition|
      next unless constraint_exists?(definition[:table], definition[:name])

      execute <<~SQL
        ALTER TABLE #{definition[:table]}
        DROP CONSTRAINT #{definition[:name]}
      SQL
    end
  end

  def add_check_constraint_if_missing!(table_name, expression, name:)
    return if check_constraint_exists?(table_name, name: name)

    execute <<~SQL
      ALTER TABLE #{table_name}
      ADD CONSTRAINT #{name}
      CHECK (#{expression})
      NOT VALID
    SQL
  end

  def remove_check_constraint_if_exists!(table_name, name)
    return unless check_constraint_exists?(table_name, name: name)

    remove_check_constraint table_name, name: name
  end

  def constraint_exists?(table_name, constraint_name)
    connection.select_value(<<~SQL).present?
      SELECT 1
      FROM pg_constraint
      WHERE conname = #{connection.quote(constraint_name)}
        AND conrelid = to_regclass(#{connection.quote("public.#{table_name}")})
      LIMIT 1
    SQL
  end
end
