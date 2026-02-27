require "test_helper"
require "digest"
require "set"

class AppendOnlyRuntimeSecurityTest < ActiveSupport::TestCase
  RLS_TEST_ROLE = "nexum_append_only_runtime_rls_tester".freeze

  APPEND_ONLY_TABLES = %w[
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
    receivable_events
    receivable_payment_settlements
  ].freeze

  setup do
    @tenant = tenants(:default)
    @secondary_tenant = tenants(:secondary)
  end

  test "functional RLS isolates append-only tables by tenant context" do
    default_rows = create_rows_for_tenant!(tenant: @tenant, suffix: "runtime-default")
    secondary_rows = create_rows_for_tenant!(tenant: @secondary_tenant, suffix: "runtime-secondary")

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      visible_tenant_ids_by_table = with_rls_enforced_role(tables: APPEND_ONLY_TABLES) do
        APPEND_ONLY_TABLES.to_h do |table_name|
          ids = [ default_rows.fetch(table_name), secondary_rows.fetch(table_name) ]
          [ table_name, tenant_ids_for_table(table_name:, ids:) ]
        end
      end

      APPEND_ONLY_TABLES.each do |table_name|
        assert_equal [ @tenant.id ], visible_tenant_ids_by_table.fetch(table_name), "#{table_name} leaked cross-tenant records"
      end
    end

    with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @secondary_tenant.id, role: "ops_admin") do
      visible_tenant_ids_by_table = with_rls_enforced_role(tables: APPEND_ONLY_TABLES) do
        APPEND_ONLY_TABLES.to_h do |table_name|
          ids = [ default_rows.fetch(table_name), secondary_rows.fetch(table_name) ]
          [ table_name, tenant_ids_for_table(table_name:, ids:) ]
        end
      end

      APPEND_ONLY_TABLES.each do |table_name|
        assert_equal [ @secondary_tenant.id ], visible_tenant_ids_by_table.fetch(table_name), "#{table_name} leaked cross-tenant records"
      end
    end
  end

  test "functional RLS rejects insert with mismatched tenant_id for append-only tables" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      bundle = create_core_bundle!(tenant: @tenant, suffix: "runtime-mismatch")
      ensure_risk_rule_for_runtime!(tenant: @secondary_tenant)

      with_rls_enforced_role(tables: APPEND_ONLY_TABLES) do
        APPEND_ONLY_TABLES.each do |table_name|
          error = assert_raises(ActiveRecord::StatementInvalid) do
            ActiveRecord::Base.transaction(requires_new: true) do
              insert_append_only_row!(
                table_name: table_name,
                tenant: @secondary_tenant,
                bundle: bundle,
                suffix: "runtime-mismatch-#{table_name}"
              )
            end
          end

          assert_match(/row-level security policy/, error.message)
        end
      end
    end
  end

  test "append-only trigger blocks UPDATE and DELETE across append-only tables" do
    rows = create_rows_for_tenant!(tenant: @tenant, suffix: "runtime-append-only")

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      APPEND_ONLY_TABLES.each do |table_name|
        row_id = rows.fetch(table_name)

        update_error = assert_raises(ActiveRecord::StatementInvalid) do
          ActiveRecord::Base.transaction(requires_new: true) do
            connection.execute("UPDATE #{table_name} SET updated_at = updated_at WHERE id = #{connection.quote(row_id)}")
          end
        end
        assert_match(/append-only table/, update_error.message)

        delete_error = assert_raises(ActiveRecord::StatementInvalid) do
          ActiveRecord::Base.transaction(requires_new: true) do
            connection.execute("DELETE FROM #{table_name} WHERE id = #{connection.quote(row_id)}")
          end
        end
        assert_match(/append-only table/, delete_error.message)
      end
    end
  end

  private

  def create_rows_for_tenant!(tenant:, suffix:)
    with_tenant_db_context(tenant_id: tenant.id, actor_id: tenant.id, role: "ops_admin") do
      bundle = create_core_bundle!(tenant:, suffix:)

      APPEND_ONLY_TABLES.each_with_object({}) do |table_name, output|
        output[table_name] = begin
          ActiveRecord::Base.transaction(requires_new: true) do
            insert_append_only_row!(table_name:, tenant:, bundle:, suffix:)
          end
        rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => error
          raise "#{table_name} setup failed: #{error.message}"
        end
      end
    end
  end

  def create_core_bundle!(tenant:, suffix:)
    hospital = Party.create!(
      tenant: tenant,
      kind: "HOSPITAL",
      legal_name: "Hospital #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-hospital")
    )

    creditor = Party.create!(
      tenant: tenant,
      kind: "SUPPLIER",
      legal_name: "Creditor #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-creditor")
    )

    beneficiary = Party.create!(
      tenant: tenant,
      kind: "SUPPLIER",
      legal_name: "Beneficiary #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-beneficiary")
    )

    receivable_kind = ReceivableKind.create!(
      tenant: tenant,
      code: "append_only_runtime_#{suffix}_#{SecureRandom.hex(4)}",
      name: "Append Only Runtime #{suffix}",
      source_family: "SUPPLIER"
    )

    receivable = Receivable.create!(
      tenant: tenant,
      receivable_kind: receivable_kind,
      debtor_party: hospital,
      creditor_party: creditor,
      beneficiary_party: beneficiary,
      external_reference: "append-only-runtime-#{suffix}-#{SecureRandom.hex(4)}",
      gross_amount: "100.00",
      currency: "BRL",
      performed_at: Time.current,
      due_at: 3.days.from_now,
      cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
    )

    allocation = ReceivableAllocation.create!(
      tenant: tenant,
      receivable: receivable,
      sequence: 1,
      allocated_party: beneficiary,
      gross_amount: "100.00",
      tax_reserve_amount: "0.00",
      status: "OPEN"
    )

    anticipation_request = AnticipationRequest.create!(
      tenant: tenant,
      receivable: receivable,
      receivable_allocation: allocation,
      requester_party: beneficiary,
      idempotency_key: "append-only-runtime-request-#{suffix}-#{SecureRandom.hex(6)}",
      requested_amount: "100.00",
      discount_rate: "0.10000000",
      discount_amount: "10.00",
      net_amount: "90.00",
      status: "APPROVED",
      channel: "API"
    )

    settlement = ReceivablePaymentSettlement.create!(
      tenant: tenant,
      receivable: receivable,
      receivable_allocation: allocation,
      paid_amount: "100.00",
      cnpj_amount: "20.00",
      fdic_amount: "30.00",
      beneficiary_amount: "50.00",
      fdic_balance_before: "30.00",
      fdic_balance_after: "0.00",
      paid_at: Time.current,
      payment_reference: "append-only-runtime-payment-#{suffix}-#{SecureRandom.hex(4)}",
      idempotency_key: "append-only-runtime-settlement-#{suffix}-#{SecureRandom.hex(6)}",
      metadata: {}
    )

    kyc_profile = KycProfile.create!(
      tenant: tenant,
      party: beneficiary,
      status: "DRAFT",
      risk_level: "UNKNOWN"
    )

    document = Document.create!(
      tenant: tenant,
      receivable: receivable,
      actor_party: beneficiary,
      document_type: "ASSIGNMENT_TERM",
      signature_method: "OWN_PLATFORM_CONFIRMATION",
      status: "SIGNED",
      sha256: Digest::SHA256.hexdigest("append-only-runtime-document-#{suffix}-#{SecureRandom.hex(4)}"),
      storage_key: "documents/#{SecureRandom.uuid}",
      signed_at: Time.current,
      metadata: {}
    )

    {
      hospital: hospital,
      creditor: creditor,
      beneficiary: beneficiary,
      receivable: receivable,
      allocation: allocation,
      anticipation_request: anticipation_request,
      settlement: settlement,
      kyc_profile: kyc_profile,
      document: document
    }
  end

  def insert_append_only_row!(table_name:, tenant:, bundle:, suffix:)
    case table_name
    when "action_ip_logs"
      ActionIpLog.create!(
        tenant: tenant,
        actor_party: bundle[:beneficiary],
        action_type: "append_only_runtime_logged",
        ip_address: "127.0.0.1",
        user_agent: "rails-test",
        request_id: "append-only-runtime-action-ip-#{suffix}-#{SecureRandom.hex(4)}",
        endpoint_path: "/api/v1/runtime",
        http_method: "POST",
        channel: "API",
        target_type: "Receivable",
        target_id: bundle[:receivable].id,
        success: true,
        occurred_at: Time.current,
        metadata: {}
      ).id
    when "anticipation_risk_decisions"
      AnticipationRiskDecision.create!(
        tenant: tenant,
        anticipation_request: bundle[:anticipation_request],
        receivable: bundle[:receivable],
        receivable_allocation: bundle[:allocation],
        requester_party: bundle[:beneficiary],
        stage: "CREATE",
        decision_action: "BLOCK",
        decision_code: "risk_limit_exceeded_daily_requested_hospital",
        decision_metric: "daily_requested",
        requested_amount: "100.00",
        net_amount: "90.00",
        request_id: "append-only-runtime-risk-decision-#{suffix}-#{SecureRandom.hex(4)}",
        idempotency_key: "append-only-runtime-risk-idem-#{suffix}-#{SecureRandom.hex(4)}",
        evaluated_at: Time.current,
        details: {}
      ).id
    when "anticipation_risk_rule_events"
      risk_rule = ensure_risk_rule_for_runtime!(tenant: tenant)
      sequence = next_sequence_for(scope: :anticipation_risk_rule_events, owner_id: risk_rule.id)
      prev_hash = risk_rule.anticipation_risk_rule_events.order(sequence: :desc).limit(1).pick(:event_hash)
      payload = {
        "source" => "append-only-runtime",
        "event_type" => "RULE_UPDATED",
        "rule_id" => risk_rule.id
      }

      AnticipationRiskRuleEvent.create!(
        tenant: tenant,
        anticipation_risk_rule: risk_rule,
        sequence: sequence,
        event_type: "RULE_UPDATED",
        actor_party: bundle[:beneficiary],
        actor_role: "ops_admin",
        request_id: "append-only-runtime-risk-rule-event-#{suffix}-#{SecureRandom.hex(4)}",
        occurred_at: Time.current,
        prev_hash: prev_hash,
        event_hash: Digest::SHA256.hexdigest("risk-rule-event:#{suffix}:#{sequence}:#{CanonicalJson.encode(payload)}"),
        payload: payload
      ).id
    when "anticipation_request_events"
      sequence = next_sequence_for(scope: :anticipation_request_events, owner_id: bundle[:anticipation_request].id)
      payload = {
        "anticipation_request_id" => bundle[:anticipation_request].id,
        "status_after" => "APPROVED"
      }

      AnticipationRequestEvent.create!(
        tenant: tenant,
        anticipation_request: bundle[:anticipation_request],
        sequence: sequence,
        event_type: "STATUS_TRANSITION",
        status_before: "REQUESTED",
        status_after: "APPROVED",
        actor_party: bundle[:beneficiary],
        actor_role: "ops_admin",
        request_id: "append-only-runtime-anticipation-event-#{suffix}-#{SecureRandom.hex(4)}",
        occurred_at: Time.current,
        prev_hash: nil,
        event_hash: Digest::SHA256.hexdigest("anticipation-request-event:#{suffix}:#{sequence}:#{CanonicalJson.encode(payload)}"),
        payload: payload
      ).id
    when "anticipation_settlement_entries"
      AnticipationSettlementEntry.create!(
        tenant: tenant,
        receivable_payment_settlement: bundle[:settlement],
        anticipation_request: bundle[:anticipation_request],
        settled_amount: "20.00",
        settled_at: Time.current,
        metadata: {}
      ).id
    when "document_events"
      DocumentEvent.create!(
        tenant: tenant,
        document: bundle[:document],
        receivable: bundle[:receivable],
        actor_party: bundle[:beneficiary],
        event_type: "DOCUMENT_SIGNED",
        occurred_at: Time.current,
        request_id: "append-only-runtime-document-event-#{suffix}-#{SecureRandom.hex(4)}",
        payload: { "source" => "append-only-runtime" }
      ).id
    when "kyc_events"
      KycEvent.create!(
        tenant: tenant,
        kyc_profile: bundle[:kyc_profile],
        party: bundle[:beneficiary],
        actor_party: bundle[:beneficiary],
        event_type: "PROFILE_CREATED",
        occurred_at: Time.current,
        request_id: "append-only-runtime-kyc-event-#{suffix}-#{SecureRandom.hex(4)}",
        payload: { "source" => "append-only-runtime" }
      ).id
    when "ledger_transactions"
      ensure_ledger_transaction!(tenant:, bundle:, suffix:).id
    when "ledger_entries"
      ensure_ledger_entries!(tenant:, bundle:, suffix:).first.id
    when "outbox_events"
      ensure_outbox_event!(tenant:, suffix:).id
    when "outbox_dispatch_attempts"
      OutboxDispatchAttempt.create!(
        tenant: tenant,
        outbox_event: ensure_outbox_event!(tenant:, suffix:),
        attempt_number: next_sequence_for(scope: :outbox_dispatch_attempts, owner_id: "#{tenant.id}:#{suffix}"),
        status: "RETRY_SCHEDULED",
        occurred_at: Time.current,
        next_attempt_at: 2.minutes.from_now,
        error_code: "temporary_error",
        error_message: "retry scheduled",
        metadata: {}
      ).id
    when "receivable_events"
      sequence = next_sequence_for(scope: :receivable_events, owner_id: bundle[:receivable].id)
      payload = { "source" => "append-only-runtime", "sequence" => sequence }

      ReceivableEvent.create!(
        tenant: tenant,
        receivable: bundle[:receivable],
        sequence: sequence,
        event_type: "RECEIVABLE_UPDATED",
        actor_party: bundle[:beneficiary],
        actor_role: "ops_admin",
        occurred_at: Time.current,
        request_id: "append-only-runtime-receivable-event-#{suffix}-#{SecureRandom.hex(4)}",
        prev_hash: nil,
        event_hash: Digest::SHA256.hexdigest("receivable-event:#{suffix}:#{sequence}:#{CanonicalJson.encode(payload)}"),
        payload: payload
      ).id
    when "receivable_payment_settlements"
      ReceivablePaymentSettlement.create!(
        tenant: tenant,
        receivable: bundle[:receivable],
        receivable_allocation: bundle[:allocation],
        paid_amount: "90.00",
        cnpj_amount: "10.00",
        fdic_amount: "20.00",
        beneficiary_amount: "60.00",
        fdic_balance_before: "20.00",
        fdic_balance_after: "0.00",
        paid_at: Time.current,
        payment_reference: "append-only-runtime-extra-payment-#{suffix}-#{SecureRandom.hex(4)}",
        idempotency_key: "append-only-runtime-extra-settlement-#{suffix}-#{SecureRandom.hex(6)}",
        metadata: {}
      ).id
    else
      raise ArgumentError, "Unknown append-only table: #{table_name}"
    end
  end

  def ensure_outbox_event!(tenant:, suffix:)
    @outbox_events_by_tenant ||= {}
    key = [ tenant.id, suffix ]

    @outbox_events_by_tenant[key] ||= OutboxEvent.create!(
      tenant: tenant,
      aggregate_type: "AppendOnlyRuntimeSecurityTest",
      aggregate_id: SecureRandom.uuid,
      event_type: "APPEND_ONLY_RUNTIME_TESTED",
      status: "PENDING",
      idempotency_key: "append-only-runtime-outbox-#{suffix}-#{SecureRandom.hex(6)}",
      payload: { "source" => "append-only-runtime", "suffix" => suffix }
    )
  end

  def ensure_risk_rule_for_runtime!(tenant:)
    @risk_rules_by_tenant ||= {}
    key = tenant.id

    @risk_rules_by_tenant[key] ||= AnticipationRiskRule.create!(
      tenant: tenant,
      scope_type: "TENANT_DEFAULT",
      decision: "BLOCK",
      priority: 100,
      max_single_request_amount: "1000.00"
    )
  end

  def ensure_ledger_transaction!(tenant:, bundle:, suffix:)
    @ledger_transactions_by_tenant ||= {}
    key = [ tenant.id, suffix ]

    @ledger_transactions_by_tenant[key] ||= begin
      payload = {
        "source" => "append-only-runtime",
        "suffix" => suffix
      }

      LedgerTransaction.create!(
        tenant: tenant,
        txn_id: SecureRandom.uuid,
        receivable: bundle[:receivable],
        source_type: "AppendOnlyRuntimeSecurityTest",
        source_id: SecureRandom.uuid,
        actor_party: bundle[:beneficiary],
        payload_hash: CanonicalJson.digest(payload),
        entry_count: 2,
        posted_at: Time.current,
        payment_reference: "append-only-runtime-ledger-#{suffix}-#{SecureRandom.hex(4)}",
        request_id: "append-only-runtime-ledger-request-#{suffix}-#{SecureRandom.hex(4)}",
        metadata: payload
      )
    end
  end

  def ensure_ledger_entries!(tenant:, bundle:, suffix:)
    @ledger_entries_by_tenant ||= {}
    key = [ tenant.id, suffix ]
    return @ledger_entries_by_tenant[key] if @ledger_entries_by_tenant.key?(key)

    transaction = ensure_ledger_transaction!(tenant:, bundle:, suffix:)
    entry_one_id = SecureRandom.uuid
    entry_two_id = SecureRandom.uuid
    timestamp = Time.current

    connection.execute(<<~SQL)
      INSERT INTO ledger_entries (
        id, tenant_id, txn_id, receivable_id, account_code, entry_side, amount, currency, party_id,
        source_type, source_id, metadata, posted_at, created_at, updated_at, entry_position, txn_entry_count, payment_reference
      ) VALUES
      (
        #{connection.quote(entry_one_id)},
        #{connection.quote(tenant.id)},
        #{connection.quote(transaction.txn_id)},
        #{connection.quote(bundle[:receivable].id)},
        'clearing:settlement',
        'DEBIT',
        10.00,
        'BRL',
        #{connection.quote(bundle[:beneficiary].id)},
        #{connection.quote(transaction.source_type)},
        #{connection.quote(transaction.source_id)},
        '{"source":"append-only-runtime"}'::jsonb,
        #{connection.quote(timestamp)},
        #{connection.quote(timestamp)},
        #{connection.quote(timestamp)},
        1,
        2,
        #{connection.quote(transaction.payment_reference)}
      ),
      (
        #{connection.quote(entry_two_id)},
        #{connection.quote(tenant.id)},
        #{connection.quote(transaction.txn_id)},
        #{connection.quote(bundle[:receivable].id)},
        'receivables:hospital',
        'CREDIT',
        10.00,
        'BRL',
        #{connection.quote(bundle[:hospital].id)},
        #{connection.quote(transaction.source_type)},
        #{connection.quote(transaction.source_id)},
        '{"source":"append-only-runtime"}'::jsonb,
        #{connection.quote(timestamp)},
        #{connection.quote(timestamp)},
        #{connection.quote(timestamp)},
        2,
        2,
        #{connection.quote(transaction.payment_reference)}
      )
    SQL

    entry_one = LedgerEntry.find(entry_one_id)
    entry_two = LedgerEntry.find(entry_two_id)
    @ledger_entries_by_tenant[key] = [ entry_one, entry_two ]
  end

  def next_sequence_for(scope:, owner_id:)
    @sequences ||= Hash.new(0)
    key = "#{scope}:#{owner_id}"
    @sequences[key] += 1
  end

  def tenant_ids_for_table(table_name:, ids:)
    values_sql = ids.map { |value| connection.quote(value) }.join(", ")

    connection.select_values(<<~SQL)
      SELECT DISTINCT tenant_id::text
      FROM #{table_name}
      WHERE id IN (#{values_sql})
      ORDER BY tenant_id::text
    SQL
  end

  def with_rls_enforced_role(tables:)
    switched_role = false

    if current_role_bypasses_rls?
      ensure_rls_test_role!(tables:)
      connection.execute("SET LOCAL ROLE #{RLS_TEST_ROLE}")
      switched_role = true
    end

    yield
  ensure
    connection.execute("RESET ROLE") if switched_role
  end

  def ensure_rls_test_role!(tables:)
    @rls_granted_tables ||= Set.new

    unless @rls_test_role_ready
      connection.execute(<<~SQL)
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{RLS_TEST_ROLE}') THEN
            CREATE ROLE #{RLS_TEST_ROLE} NOLOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOBYPASSRLS;
          END IF;
        END
        $$;
      SQL
      connection.execute("GRANT #{RLS_TEST_ROLE} TO CURRENT_USER")
      connection.execute("GRANT USAGE ON SCHEMA public TO #{RLS_TEST_ROLE}")
      @rls_test_role_ready = true
    end

    (tables.map(&:to_s) - @rls_granted_tables.to_a).each do |table_name|
      connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE #{table_name} TO #{RLS_TEST_ROLE}")
      @rls_granted_tables << table_name
    end
  end

  def current_role_bypasses_rls?
    row = connection.select_one(<<~SQL)
      SELECT r.rolsuper, r.rolbypassrls
      FROM pg_roles r
      WHERE r.rolname = current_user
    SQL

    row["rolsuper"] || row["rolbypassrls"]
  end

  def connection
    ActiveRecord::Base.connection
  end
end
