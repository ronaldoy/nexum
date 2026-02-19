require "test_helper"

class EscrowAccountTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
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
end
