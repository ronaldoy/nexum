require "test_helper"

class EscrowAccountTest < ActiveSupport::TestCase
  RLS_TEST_ROLE = "nexum_escrow_rls_tester".freeze

  setup do
    @tenant = tenants(:default)
    @secondary_tenant = tenants(:secondary)
  end

  test "validates provider inclusion" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      party = Party.create!(
        tenant: @tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor Escrow",
        document_number: valid_cnpj_from_seed("escrow-account-provider")
      )

      account = EscrowAccount.new(
        tenant: @tenant,
        party: party,
        provider: "UNKNOWN",
        account_type: "ESCROW",
        status: "PENDING"
      )

      assert_not account.valid?
      assert_includes account.errors[:provider], "is not included in the list"
    end
  end

  test "enables and forces RLS with tenant policy for escrow tables" do
    connection = ActiveRecord::Base.connection

    %w[escrow_accounts escrow_payouts].each do |table_name|
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
          AND tablename = '#{table_name}'
          AND policyname = '#{table_name}_tenant_policy'
      SQL

      assert policy.present?, "#{table_name} tenant policy must exist"
      assert_includes policy["qual"], "tenant_id"
      assert_includes policy["with_check"], "tenant_id"
    end
  end

  test "functional RLS isolates escrow_accounts by app.tenant_id" do
    default_account = nil
    secondary_account = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      default_account = create_escrow_account!(tenant: @tenant, suffix: "escrow-rls-default")
    end

    with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @secondary_tenant.id, role: "ops_admin") do
      secondary_account = create_escrow_account!(tenant: @secondary_tenant, suffix: "escrow-rls-secondary")
    end

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      visible_tenant_ids = with_rls_enforced_role do
        EscrowAccount.where(id: [ default_account.id, secondary_account.id ]).pluck(:tenant_id).uniq
      end

      assert_equal [ @tenant.id ], visible_tenant_ids
    end

    with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @secondary_tenant.id, role: "ops_admin") do
      visible_tenant_ids = with_rls_enforced_role do
        EscrowAccount.where(id: [ default_account.id, secondary_account.id ]).pluck(:tenant_id).uniq
      end

      assert_equal [ @secondary_tenant.id ], visible_tenant_ids
    end
  end

  private

  def create_escrow_account!(tenant:, suffix:)
    party = Party.create!(
      tenant: tenant,
      kind: "SUPPLIER",
      legal_name: "Fornecedor #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-supplier")
    )

    EscrowAccount.create!(
      tenant: tenant,
      party: party,
      provider: "STARKBANK",
      account_type: "ESCROW",
      status: "ACTIVE",
      provider_account_id: "workspace-#{suffix}",
      provider_request_id: "workspace-request-#{suffix}",
      metadata: {}
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
    connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE escrow_accounts TO #{RLS_TEST_ROLE}")

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
