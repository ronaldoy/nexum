require "test_helper"

class OutboxEventTest < ActiveSupport::TestCase
  RLS_TEST_ROLE = "nexum_outbox_rls_tester".freeze

  setup do
    @tenant = tenants(:default)
    @secondary_tenant = tenants(:secondary)
  end

  test "auto-populates payload hash for idempotent outbox events" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      event = create_outbox_event!(
        tenant: @tenant,
        aggregate_id: SecureRandom.uuid,
        idempotency_key: "outbox-auto-hash-#{SecureRandom.hex(6)}",
        payload: { "kind" => "test_event", "reference" => "abc-123" }
      )

      assert event.payload["payload_hash"].present?
      assert_equal 64, event.payload["payload_hash"].length
    end
  end

  test "preserves explicit payload hash when provided by service layer" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      event = create_outbox_event!(
        tenant: @tenant,
        aggregate_id: SecureRandom.uuid,
        idempotency_key: "outbox-explicit-hash-#{SecureRandom.hex(6)}",
        payload: {
          "payload_hash" => "a" * 64,
          "kind" => "test_event"
        }
      )

      assert_equal "a" * 64, event.payload["payload_hash"]
    end
  end

  test "enables and forces RLS with tenant policy on outbox events" do
    connection = ActiveRecord::Base.connection

    rls_row = connection.select_one(<<~SQL)
      SELECT relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE oid = 'outbox_events'::regclass
    SQL

    assert_equal true, rls_row["relrowsecurity"]
    assert_equal true, rls_row["relforcerowsecurity"]

    policy = connection.select_one(<<~SQL)
      SELECT policyname, qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'outbox_events'
        AND policyname = 'outbox_events_tenant_policy'
    SQL

    assert policy.present?
    assert_includes policy["qual"], "tenant_id"
    assert_includes policy["with_check"], "tenant_id"
  end

  test "functional RLS isolates outbox events by app.tenant_id" do
    default_event = nil
    secondary_event = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      default_event = create_outbox_event!(
        tenant: @tenant,
        aggregate_id: SecureRandom.uuid,
        idempotency_key: "outbox-rls-default-#{SecureRandom.hex(6)}",
        payload: { "source" => "default" }
      )
    end

    with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @secondary_tenant.id, role: "ops_admin") do
      secondary_event = create_outbox_event!(
        tenant: @secondary_tenant,
        aggregate_id: SecureRandom.uuid,
        idempotency_key: "outbox-rls-secondary-#{SecureRandom.hex(6)}",
        payload: { "source" => "secondary" }
      )
    end

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      visible_tenant_ids = with_rls_enforced_role do
        OutboxEvent.where(id: [ default_event.id, secondary_event.id ]).pluck(:tenant_id).uniq
      end
      assert_equal [ @tenant.id ], visible_tenant_ids
    end

    with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @secondary_tenant.id, role: "ops_admin") do
      visible_tenant_ids = with_rls_enforced_role do
        OutboxEvent.where(id: [ default_event.id, secondary_event.id ]).pluck(:tenant_id).uniq
      end
      assert_equal [ @secondary_tenant.id ], visible_tenant_ids
    end
  end

  test "functional RLS rejects insert with mismatched tenant_id" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      error = assert_raises(ActiveRecord::StatementInvalid) do
        with_rls_enforced_role do
          create_outbox_event!(
            tenant: @secondary_tenant,
            aggregate_id: SecureRandom.uuid,
            idempotency_key: "outbox-rls-mismatch-#{SecureRandom.hex(6)}",
            payload: { "source" => "forbidden-cross-tenant" }
          )
        end
      end

      assert_match(/row-level security policy/, error.message)
    end
  end

  test "append-only trigger blocks UPDATE on outbox events" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      event = create_outbox_event!(
        tenant: @tenant,
        aggregate_id: SecureRandom.uuid,
        idempotency_key: "outbox-append-update-#{SecureRandom.hex(6)}",
        payload: { "source" => "append-only" }
      )

      error = assert_raises(ActiveRecord::StatementInvalid) do
        event.update!(status: "SENT")
      end

      assert_match(/append-only table/, error.message)
    end
  end

  test "append-only trigger blocks DELETE on outbox events" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      event = create_outbox_event!(
        tenant: @tenant,
        aggregate_id: SecureRandom.uuid,
        idempotency_key: "outbox-append-delete-#{SecureRandom.hex(6)}",
        payload: { "source" => "append-only" }
      )

      error = assert_raises(ActiveRecord::StatementInvalid) do
        event.destroy!
      end

      assert_match(/append-only table/, error.message)
    end
  end

  test "db guardrail rejects idempotent outbox rows without payload hash after rollout cutoff" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      connection = ActiveRecord::Base.connection
      timestamp = Time.utc(2026, 2, 22, 0, 0, 1)

      error = assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true) do
          connection.execute(<<~SQL)
            INSERT INTO outbox_events (
              id, tenant_id, aggregate_type, aggregate_id, event_type, status, attempts, idempotency_key, payload, created_at, updated_at
            ) VALUES (
              #{connection.quote(SecureRandom.uuid)},
              #{connection.quote(@tenant.id)},
              'OutboxGuardrail',
              #{connection.quote(SecureRandom.uuid)},
              'OUTBOX_GUARDRAIL_TESTED',
              'PENDING',
              0,
              'outbox-missing-hash-after-cutoff',
              '{}'::jsonb,
              #{connection.quote(timestamp)},
              #{connection.quote(timestamp)}
            )
          SQL
        end
      end

      assert_match(/outbox_events_idempotency_payload_hash_present_check/, error.message)
    end
  end

  test "db guardrail allows legacy idempotent outbox rows before rollout cutoff" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      connection = ActiveRecord::Base.connection
      timestamp = Time.utc(2026, 2, 21, 23, 59, 59)
      outbox_id = SecureRandom.uuid

      connection.execute(<<~SQL)
        INSERT INTO outbox_events (
          id, tenant_id, aggregate_type, aggregate_id, event_type, status, attempts, idempotency_key, payload, created_at, updated_at
        ) VALUES (
          #{connection.quote(outbox_id)},
          #{connection.quote(@tenant.id)},
          'OutboxGuardrail',
          #{connection.quote(SecureRandom.uuid)},
          'OUTBOX_GUARDRAIL_LEGACY',
          'PENDING',
          0,
          'outbox-missing-hash-before-cutoff',
          '{}'::jsonb,
          #{connection.quote(timestamp)},
          #{connection.quote(timestamp)}
        )
      SQL

      row = OutboxEvent.find(outbox_id)
      assert_equal({}, row.payload)
    end
  end

  private

  def create_outbox_event!(tenant:, aggregate_id:, idempotency_key:, payload:)
    OutboxEvent.create!(
      tenant: tenant,
      aggregate_type: "OutboxEventTest",
      aggregate_id: aggregate_id,
      event_type: "OUTBOX_EVENT_TESTED",
      status: "PENDING",
      idempotency_key: idempotency_key,
      payload: payload
    )
  end

  def with_rls_enforced_role
    connection = ActiveRecord::Base.connection
    switched_role = false

    if current_role_bypasses_rls?
      ensure_rls_test_role!
      connection.execute("SET LOCAL ROLE #{RLS_TEST_ROLE}")
      switched_role = true
    end

    yield
  ensure
    connection.execute("RESET ROLE") if switched_role
  end

  def ensure_rls_test_role!
    return if @rls_test_role_ready

    connection = ActiveRecord::Base.connection
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
    connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE outbox_events TO #{RLS_TEST_ROLE}")

    @rls_test_role_ready = true
  end

  def current_role_bypasses_rls?
    row = ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT r.rolsuper, r.rolbypassrls
      FROM pg_roles r
      WHERE r.rolname = current_user
    SQL

    row["rolsuper"] || row["rolbypassrls"]
  end
end
