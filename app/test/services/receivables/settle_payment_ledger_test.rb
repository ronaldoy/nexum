require "test_helper"

module Receivables
  class SettlePaymentLedgerTest < ActiveSupport::TestCase
    RLS_TEST_ROLE = "nexum_rls_tester".freeze

    setup do
      @tenant = tenants(:default)
      @request_id = SecureRandom.uuid
    end

    test "settlement creates ledger entries atomically" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_shared_cnpj_physician_bundle!("ledger-int-1")
        create_direct_anticipation_request!(
          tenant_bundle: bundle,
          idempotency_key: "ledger-int-antic-1",
          requested_amount: "60.00",
          discount_rate: "0.10000000",
          discount_amount: "6.00",
          net_amount: "54.00",
          status: "APPROVED"
        )

        result = settle_service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "ledger-int-payment-001"
        )

        settlement = result.settlement
        ledger_entries = LedgerEntry.where(tenant_id: @tenant.id, source_type: "ReceivablePaymentSettlement", source_id: settlement.id).to_a

        assert ledger_entries.size >= 4, "Expected at least 4 ledger entries, got #{ledger_entries.size}"

        debit_sum = ledger_entries.select { |e| e.entry_side == "DEBIT" }.sum { |e| e.amount.to_d }
        credit_sum = ledger_entries.select { |e| e.entry_side == "CREDIT" }.sum { |e| e.amount.to_d }
        assert_equal debit_sum, credit_sum, "Ledger entries must be balanced"
      end
    end

    test "ledger entries reference correct settlement as source" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("ledger-int-src-1")

        result = settle_service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "ledger-int-payment-002"
        )

        settlement = result.settlement
        ledger_entries = LedgerEntry.where(tenant_id: @tenant.id, source_type: "ReceivablePaymentSettlement", source_id: settlement.id)

        assert ledger_entries.any?, "Expected ledger entries to be created"
        assert ledger_entries.all? { |e| e.source_type == "ReceivablePaymentSettlement" }
        assert ledger_entries.all? { |e| e.source_id == settlement.id }
        assert ledger_entries.all? { |e| e.receivable_id == bundle[:receivable].id }
        assert ledger_entries.all? { |e| e.payment_reference == "ledger-int-payment-002" }
      end
    end

    test "idempotent replay does not duplicate ledger entries" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("ledger-int-idem")

        first = settle_service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "ledger-int-payment-003"
        )

        entries_after_first = LedgerEntry.where(tenant_id: @tenant.id, source_type: "ReceivablePaymentSettlement", source_id: first.settlement.id).count

        second = settle_service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: first.settlement.paid_at,
          payment_reference: "ledger-int-payment-003"
        )

        assert_equal true, second.replayed?
        entries_after_second = LedgerEntry.where(tenant_id: @tenant.id, source_type: "ReceivablePaymentSettlement", source_id: first.settlement.id).count
        assert_equal entries_after_first, entries_after_second, "Replay must not duplicate ledger entries"
      end
    end

    test "append-only: DB blocks UPDATE on ledger_entries" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("ledger-int-append-upd")
        result = settle_service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "ledger-int-payment-004"
        )

        entry = LedgerEntry.where(tenant_id: @tenant.id, source_id: result.settlement.id).first
        assert entry.present?

        error = assert_raises(ActiveRecord::StatementInvalid) do
          ActiveRecord::Base.transaction(requires_new: true) do
            ActiveRecord::Base.connection.execute(
              "UPDATE ledger_entries SET amount = 999.99 WHERE id = '#{entry.id}'"
            )
          end
        end

        assert_match(/append-only table/, error.message)
      end
    end

    test "append-only: DB blocks DELETE on ledger_entries" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("ledger-int-append-del")
        result = settle_service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "ledger-int-payment-005"
        )

        entry = LedgerEntry.where(tenant_id: @tenant.id, source_id: result.settlement.id).first
        assert entry.present?

        error = assert_raises(ActiveRecord::StatementInvalid) do
          ActiveRecord::Base.transaction(requires_new: true) do
            ActiveRecord::Base.connection.execute(
              "DELETE FROM ledger_entries WHERE id = '#{entry.id}'"
            )
          end
        end

        assert_match(/append-only table/, error.message)
      end
    end

    test "DB constraints block inserts beyond finalized transaction size" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        txn_id = SecureRandom.uuid
        payment_reference = "ledger-int-identity-001"
        Ledger::PostTransaction.new(tenant_id: @tenant.id, request_id: @request_id).call(
          txn_id: txn_id,
          posted_at: Time.current,
          source_type: "LedgerSqlTest",
          source_id: sql_source_id_for(txn_id),
          payment_reference: payment_reference,
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: "10.00" },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: "10.00" }
          ]
        )

        error = assert_raises(ActiveRecord::StatementInvalid) do
          ActiveRecord::Base.transaction(requires_new: true) do
            insert_ledger_entry_sql!(
              tenant_id: @tenant.id,
              txn_id: txn_id,
              entry_position: 3,
              txn_entry_count: 2,
              account_code: "obligations:beneficiary",
              entry_side: "DEBIT",
              amount: "1.00",
              payment_reference: payment_reference
            )
          end
        end

        assert_match(/entry_position|check/, error.message)
      end
    end

    test "DB trigger rejects unbalanced ledger transaction at commit" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        txn_id = SecureRandom.uuid

        error = assert_raises(ActiveRecord::StatementInvalid) do
          ActiveRecord::Base.transaction(requires_new: true) do
            insert_ledger_entry_sql!(
              tenant_id: @tenant.id,
              txn_id: txn_id,
              entry_position: 1,
              txn_entry_count: 1,
              account_code: "clearing:settlement",
              entry_side: "DEBIT",
              amount: "100.00"
            )
          end
        end

        assert_match(/unbalanced ledger transaction/, error.message)
      end
    end

    test "DB trigger rejects incomplete ledger transaction at commit" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        txn_id = SecureRandom.uuid

        error = assert_raises(ActiveRecord::StatementInvalid) do
          ActiveRecord::Base.transaction(requires_new: true) do
            insert_ledger_entry_sql!(
              tenant_id: @tenant.id,
              txn_id: txn_id,
              entry_position: 1,
              txn_entry_count: 2,
              account_code: "clearing:settlement",
              entry_side: "DEBIT",
              amount: "100.00"
            )
          end
        end

        assert_match(/incomplete ledger transaction/, error.message)
      end
    end

    test "DB requires payment_reference for settlement ledger sources" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        txn_id = SecureRandom.uuid

        error = assert_raises(ActiveRecord::StatementInvalid) do
          ActiveRecord::Base.transaction(requires_new: true) do
            insert_ledger_entry_sql!(
              tenant_id: @tenant.id,
              txn_id: txn_id,
              entry_position: 1,
              txn_entry_count: 1,
              account_code: "clearing:settlement",
              entry_side: "DEBIT",
              amount: "100.00",
              source_type: "ReceivablePaymentSettlement",
              payment_reference: nil
            )
          end
        end

        assert_match(/payment_reference|required/, error.message)
      end
    end

    test "functional RLS isolates ledger_entries by app.tenant_id" do
      secondary_tenant = tenants(:secondary)
      default_txn_id = create_minimal_ledger_txn!(tenant: @tenant)
      secondary_txn_id = create_minimal_ledger_txn!(tenant: secondary_tenant)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        visible_tenant_ids = with_rls_enforced_role do
          LedgerEntry.where(txn_id: [ default_txn_id, secondary_txn_id ]).pluck(:tenant_id).uniq
        end
        assert_equal [ @tenant.id ], visible_tenant_ids
      end

      with_tenant_db_context(tenant_id: secondary_tenant.id, actor_id: secondary_tenant.id, role: "ops_admin") do
        visible_tenant_ids = with_rls_enforced_role do
          LedgerEntry.where(txn_id: [ default_txn_id, secondary_txn_id ]).pluck(:tenant_id).uniq
        end
        assert_equal [ secondary_tenant.id ], visible_tenant_ids
      end
    end

    test "functional RLS rejects insert with mismatched tenant_id" do
      secondary_tenant = tenants(:secondary)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        txn_id = SecureRandom.uuid
        error = assert_raises(ActiveRecord::StatementInvalid) do
          with_rls_enforced_role do
            ActiveRecord::Base.transaction(requires_new: true) do
              insert_ledger_entry_sql!(
                tenant_id: secondary_tenant.id,
                txn_id: txn_id,
                entry_position: 1,
                txn_entry_count: 2,
                account_code: "clearing:settlement",
                entry_side: "DEBIT",
                amount: "10.00"
              )
              insert_ledger_entry_sql!(
                tenant_id: secondary_tenant.id,
                txn_id: txn_id,
                entry_position: 2,
                txn_entry_count: 2,
                account_code: "receivables:hospital",
                entry_side: "CREDIT",
                amount: "10.00"
              )
            end
          end
        end

        assert_match(/row-level security policy/, error.message)
      end
    end

    test "RLS policy exists on ledger_entries" do
      policy = ActiveRecord::Base.connection.select_one(<<~SQL)
        SELECT policyname, cmd, qual
        FROM pg_policies
        WHERE tablename = 'ledger_entries'
          AND policyname = 'ledger_entries_tenant_policy'
      SQL

      assert policy.present?, "RLS policy must exist on ledger_entries"
      assert_equal "ledger_entries_tenant_policy", policy["policyname"]
    end

    test "RLS is forced on ledger_entries" do
      row = ActiveRecord::Base.connection.select_one(<<~SQL)
        SELECT relrowsecurity, relforcerowsecurity
        FROM pg_class
        WHERE relname = 'ledger_entries'
      SQL

      assert_equal true, row["relrowsecurity"], "RLS must be enabled"
      assert_equal true, row["relforcerowsecurity"], "RLS must be forced"
    end

    private

    def settle_service
      Receivables::SettlePayment.new(
        tenant_id: @tenant.id,
        actor_role: "ops_admin",
        request_id: @request_id,
        idempotency_key: "test-idempotency-#{@request_id}",
        request_ip: "127.0.0.1",
        user_agent: "rails-test",
        endpoint_path: "/api/v1/receivables/settlements",
        http_method: "POST"
      )
    end

    def create_supplier_bundle!(suffix)
      debtor = Party.create!(tenant: @tenant, kind: "HOSPITAL", legal_name: "Hospital #{suffix}", document_number: valid_cnpj_from_seed("#{suffix}-hospital"))
      supplier = Party.create!(tenant: @tenant, kind: "SUPPLIER", legal_name: "Fornecedor #{suffix}", document_number: valid_cnpj_from_seed("#{suffix}-supplier"))

      kind = ReceivableKind.create!(tenant: @tenant, code: "supplier_invoice_#{suffix}", name: "Supplier Invoice #{suffix}", source_family: "SUPPLIER")
      receivable = Receivable.create!(
        tenant: @tenant, receivable_kind: kind,
        debtor_party: debtor, creditor_party: supplier, beneficiary_party: supplier,
        external_reference: "external-#{suffix}", gross_amount: "100.00", currency: "BRL",
        performed_at: Time.current, due_at: 3.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant, receivable: receivable, sequence: 1,
        allocated_party: supplier, gross_amount: "100.00",
        tax_reserve_amount: "0.00", status: "OPEN"
      )

      { debtor: debtor, supplier: supplier, receivable: receivable, allocation: allocation }
    end

    def create_shared_cnpj_physician_bundle!(suffix)
      hospital = Party.create!(tenant: @tenant, kind: "HOSPITAL", legal_name: "Hospital #{suffix}", document_number: valid_cnpj_from_seed("#{suffix}-hospital"))
      legal_entity = Party.create!(tenant: @tenant, kind: "LEGAL_ENTITY_PJ", legal_name: "Clinica #{suffix}", document_number: valid_cnpj_from_seed("#{suffix}-legal-entity"))
      physician_one = Party.create!(tenant: @tenant, kind: "PHYSICIAN_PF", legal_name: "Medico Um #{suffix}", document_number: valid_cpf_from_seed("#{suffix}-physician-1"))
      Party.find_or_create_by!(tenant: @tenant, kind: "FIDC") do |p|
        p.legal_name = "FIDC #{suffix}"
        p.document_number = valid_cnpj_from_seed("#{suffix}-fdic")
      end

      PhysicianLegalEntityMembership.create!(
        tenant: @tenant, physician_party: physician_one,
        legal_entity_party: legal_entity, membership_role: "ADMIN", status: "ACTIVE"
      )

      kind = ReceivableKind.create!(tenant: @tenant, code: "physician_shift_#{suffix}", name: "Physician Shift #{suffix}", source_family: "PHYSICIAN")
      receivable = Receivable.create!(
        tenant: @tenant, receivable_kind: kind,
        debtor_party: hospital, creditor_party: legal_entity, beneficiary_party: legal_entity,
        external_reference: "external-#{suffix}", gross_amount: "100.00", currency: "BRL",
        performed_at: Time.current, due_at: 3.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant, receivable: receivable, sequence: 1,
        allocated_party: legal_entity, physician_party: physician_one,
        gross_amount: "100.00", tax_reserve_amount: "0.00", status: "OPEN"
      )

      { hospital: hospital, legal_entity: legal_entity, physician_one: physician_one, receivable: receivable, allocation: allocation }
    end

    def create_direct_anticipation_request!(tenant_bundle:, idempotency_key:, requested_amount:, discount_rate:, discount_amount:, net_amount:, status:)
      AnticipationRequest.create!(
        tenant: @tenant,
        receivable: tenant_bundle[:receivable],
        receivable_allocation: tenant_bundle[:allocation],
        requester_party: tenant_bundle[:allocation].physician_party || tenant_bundle[:supplier],
        idempotency_key: idempotency_key,
        requested_amount: requested_amount,
        discount_rate: discount_rate,
        discount_amount: discount_amount,
        net_amount: net_amount,
        status: status,
        channel: "API",
        requested_at: Time.current,
        settlement_target_date: BusinessCalendar.next_business_day(from: Time.current),
        metadata: {}
      )
    end

    def create_minimal_ledger_txn!(tenant:)
      txn_id = SecureRandom.uuid

      with_tenant_db_context(tenant_id: tenant.id, actor_id: tenant.id, role: "ops_admin") do
        Ledger::PostTransaction.new(tenant_id: tenant.id, request_id: SecureRandom.uuid).call(
          txn_id: txn_id,
          posted_at: Time.current,
          source_type: "LedgerRlsTest",
          source_id: SecureRandom.uuid,
          payment_reference: "ledger-rls-#{txn_id}",
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: "10.00" },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: "10.00" }
          ]
        )
      end

      txn_id
    end

    def insert_ledger_entry_sql!(tenant_id:, txn_id:, entry_position:, txn_entry_count:, account_code:, entry_side:, amount:, payment_reference: nil, source_type: "LedgerSqlTest", source_id: nil)
      connection = ActiveRecord::Base.connection
      now = Time.current
      effective_source_id = source_id || sql_source_id_for(txn_id)

      ensure_ledger_transaction_header_sql!(
        tenant_id: tenant_id,
        txn_id: txn_id,
        source_type: source_type,
        source_id: effective_source_id,
        payment_reference: payment_reference,
        entry_count: txn_entry_count,
        posted_at: now
      )

      connection.execute(<<~SQL)
        INSERT INTO ledger_entries (
          id, tenant_id, txn_id, entry_position, txn_entry_count, account_code, entry_side, amount, currency, payment_reference,
          source_type, source_id, metadata, posted_at, created_at, updated_at
        ) VALUES (
          #{connection.quote(SecureRandom.uuid)},
          #{connection.quote(tenant_id)},
          #{connection.quote(txn_id)},
          #{connection.quote(entry_position)},
          #{connection.quote(txn_entry_count)},
          #{connection.quote(account_code)},
          #{connection.quote(entry_side)},
          #{connection.quote(amount)},
          'BRL',
          #{connection.quote(payment_reference)},
          #{connection.quote(source_type)},
          #{connection.quote(effective_source_id)},
          '{}'::jsonb,
          #{connection.quote(now)},
          #{connection.quote(now)},
          #{connection.quote(now)}
        )
      SQL
    end

    def ensure_ledger_transaction_header_sql!(tenant_id:, txn_id:, source_type:, source_id:, payment_reference:, entry_count:, posted_at:)
      connection = ActiveRecord::Base.connection
      now = Time.current

      connection.execute(<<~SQL)
        INSERT INTO ledger_transactions (
          id, tenant_id, txn_id, source_type, source_id, payment_reference, payload_hash, entry_count, posted_at, metadata, created_at, updated_at
        ) VALUES (
          #{connection.quote(SecureRandom.uuid)},
          #{connection.quote(tenant_id)},
          #{connection.quote(txn_id)},
          #{connection.quote(source_type)},
          #{connection.quote(source_id)},
          #{connection.quote(payment_reference)},
          #{connection.quote("0" * 64)},
          #{connection.quote(entry_count)},
          #{connection.quote(posted_at)},
          '{}'::jsonb,
          #{connection.quote(now)},
          #{connection.quote(now)}
        )
        ON CONFLICT (tenant_id, txn_id) DO NOTHING
      SQL
    end

    def sql_source_id_for(txn_id)
      @sql_source_ids ||= {}
      @sql_source_ids[txn_id] ||= SecureRandom.uuid
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
      connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE ledger_entries TO #{RLS_TEST_ROLE}")
      connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE ledger_transactions TO #{RLS_TEST_ROLE}")

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
end
