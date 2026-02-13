require "test_helper"

module Receivables
  class SettlePaymentLedgerTest < ActiveSupport::TestCase
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
  end
end
