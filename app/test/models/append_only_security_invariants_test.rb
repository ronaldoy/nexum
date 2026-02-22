require "test_helper"
require "digest"

class AppendOnlySecurityInvariantsTest < ActiveSupport::TestCase
  RLS_TEST_ROLE = "nexum_append_only_rls_tester".freeze

  REQUIRED_APPEND_ONLY_TABLES = %w[
    action_ip_logs
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

  test "append-only trigger coverage matches required table set" do
    assert_equal REQUIRED_APPEND_ONLY_TABLES.sort, append_only_tables
  end

  test "append-only tables enforce forced RLS with tenant policies" do
    append_only_tables.each do |table_name|
      rls_row = connection.select_one(<<~SQL)
        SELECT relrowsecurity, relforcerowsecurity
        FROM pg_class
        WHERE oid = '#{table_name}'::regclass
      SQL

      assert_equal true, rls_row["relrowsecurity"], "#{table_name} must have RLS enabled"
      assert_equal true, rls_row["relforcerowsecurity"], "#{table_name} must have forced RLS"

      policy = connection.select_one(<<~SQL)
        SELECT policyname, qual, with_check
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = #{connection.quote(table_name)}
          AND policyname = #{connection.quote("#{table_name}_tenant_policy")}
      SQL

      assert policy.present?, "#{table_name} must define tenant policy"
      assert_includes policy["qual"], "tenant_id"
      assert_includes policy["with_check"], "tenant_id"
    end
  end

  test "functional RLS isolates receivable events by app.tenant_id" do
    default_event = nil
    secondary_event = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      default_bundle = create_receivable_bundle!(tenant: @tenant, suffix: "rls-default")
      default_event = create_receivable_event!(
        tenant: @tenant,
        receivable: default_bundle[:receivable],
        sequence: 1,
        seed: "default"
      )
    end

    with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @secondary_tenant.id, role: "ops_admin") do
      secondary_bundle = create_receivable_bundle!(tenant: @secondary_tenant, suffix: "rls-secondary")
      secondary_event = create_receivable_event!(
        tenant: @secondary_tenant,
        receivable: secondary_bundle[:receivable],
        sequence: 1,
        seed: "secondary"
      )
    end

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      visible_tenant_ids = with_rls_enforced_role(tables: %w[receivable_events]) do
        ReceivableEvent.where(id: [ default_event.id, secondary_event.id ]).pluck(:tenant_id).uniq
      end

      assert_equal [ @tenant.id ], visible_tenant_ids
    end

    with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @secondary_tenant.id, role: "ops_admin") do
      visible_tenant_ids = with_rls_enforced_role(tables: %w[receivable_events]) do
        ReceivableEvent.where(id: [ default_event.id, secondary_event.id ]).pluck(:tenant_id).uniq
      end

      assert_equal [ @secondary_tenant.id ], visible_tenant_ids
    end
  end

  test "functional RLS rejects receivable event insert with mismatched tenant_id" do
    default_bundle = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      default_bundle = create_receivable_bundle!(tenant: @tenant, suffix: "rls-mismatch-default")
    end

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      error = assert_raises(ActiveRecord::StatementInvalid) do
        with_rls_enforced_role(tables: %w[receivable_events]) do
          create_receivable_event!(
            tenant: @secondary_tenant,
            receivable: default_bundle[:receivable],
            sequence: 11,
            seed: "cross-tenant"
          )
        end
      end

      assert_match(/row-level security policy/, error.message)
    end
  end

  test "append-only trigger blocks UPDATE and DELETE on receivable events" do
    event = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      bundle = create_receivable_bundle!(tenant: @tenant, suffix: "append-receivable")
      event = create_receivable_event!(
        tenant: @tenant,
        receivable: bundle[:receivable],
        sequence: 2,
        seed: "append"
      )
    end

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      update_error = assert_raises(ActiveRecord::StatementInvalid) do
        event.update!(event_type: "RECEIVABLE_EVENT_MUTATED")
      end
      assert_match(/append-only table/, update_error.message)

      delete_error = assert_raises(ActiveRecord::StatementInvalid) do
        event.destroy!
      end
      assert_match(/append-only table/, delete_error.message)
    end
  end

  test "append-only trigger blocks UPDATE and DELETE on document events" do
    event = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      bundle = create_receivable_bundle!(tenant: @tenant, suffix: "append-document")

      document = Document.create!(
        tenant: @tenant,
        receivable: bundle[:receivable],
        actor_party: bundle[:beneficiary],
        document_type: "ASSIGNMENT_TERM",
        signature_method: "OWN_PLATFORM_CONFIRMATION",
        status: "SIGNED",
        sha256: Digest::SHA256.hexdigest("append-document-#{SecureRandom.hex(8)}"),
        storage_key: "documents/#{SecureRandom.uuid}",
        signed_at: Time.current,
        metadata: { "source" => "append-only-test" }
      )

      event = DocumentEvent.create!(
        tenant: @tenant,
        document: document,
        receivable: bundle[:receivable],
        actor_party: bundle[:beneficiary],
        event_type: "DOCUMENT_SIGNED",
        occurred_at: Time.current,
        request_id: "document-append-#{SecureRandom.hex(6)}",
        payload: { "source" => "append-only-test" }
      )
    end

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      update_error = assert_raises(ActiveRecord::StatementInvalid) do
        event.update!(event_type: "DOCUMENT_EVENT_MUTATED")
      end
      assert_match(/append-only table/, update_error.message)

      delete_error = assert_raises(ActiveRecord::StatementInvalid) do
        event.destroy!
      end
      assert_match(/append-only table/, delete_error.message)
    end
  end

  private

  def append_only_tables
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

  def create_receivable_bundle!(tenant:, suffix:)
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
      code: "security_invariant_#{suffix}_#{SecureRandom.hex(4)}",
      name: "Security Invariant #{suffix}",
      source_family: "SUPPLIER"
    )

    receivable = Receivable.create!(
      tenant: tenant,
      receivable_kind: receivable_kind,
      debtor_party: hospital,
      creditor_party: creditor,
      beneficiary_party: beneficiary,
      external_reference: "security-invariant-#{suffix}-#{SecureRandom.hex(4)}",
      gross_amount: "100.00",
      currency: "BRL",
      performed_at: Time.current,
      due_at: 3.days.from_now,
      cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
    )

    {
      hospital: hospital,
      creditor: creditor,
      beneficiary: beneficiary,
      receivable: receivable
    }
  end

  def create_receivable_event!(tenant:, receivable:, sequence:, seed:)
    ReceivableEvent.create!(
      tenant: tenant,
      receivable: receivable,
      sequence: sequence,
      event_type: "RECEIVABLE_EVENT_#{seed.upcase}",
      actor_party: receivable.beneficiary_party,
      actor_role: "ops_admin",
      occurred_at: Time.current,
      request_id: "req-#{seed}-#{SecureRandom.hex(6)}",
      prev_hash: nil,
      event_hash: Digest::SHA256.hexdigest("#{seed}-#{sequence}-#{SecureRandom.hex(8)}"),
      payload: { "seed" => seed }
    )
  end

  def with_rls_enforced_role(tables:)
    switched_role = false

    if current_role_bypasses_rls?
      ensure_rls_test_role!(tables: tables)
      connection.execute("SET LOCAL ROLE #{RLS_TEST_ROLE}")
      switched_role = true
    end

    yield
  ensure
    connection.execute("RESET ROLE") if switched_role
  end

  def ensure_rls_test_role!(tables:)
    return if @rls_test_role_ready

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
    tables.each do |table_name|
      connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE #{table_name} TO #{RLS_TEST_ROLE}")
    end

    @rls_test_role_ready = true
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
