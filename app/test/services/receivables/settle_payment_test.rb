require "test_helper"

module Receivables
  class SettlePaymentTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @request_id = SecureRandom.uuid
    end

    test "settles shared cnpj payment splitting cnpj, fdic and physician remainder" do
      result = nil
      anticipation_request = nil

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_shared_cnpj_physician_bundle!("shared-cnpj-1")
        anticipation_request = create_direct_anticipation_request!(
          tenant_bundle: bundle,
          idempotency_key: "settle-shared-cnpj-1",
          requested_amount: "60.00",
          discount_rate: "0.10000000",
          discount_amount: "6.00",
          net_amount: "54.00",
          status: "APPROVED"
        )

        result = service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "hospital-payment-shared-001",
          metadata: { source: "hospital_erp" }
        )

        settlement = result.settlement
        assert_equal false, result.replayed?
        assert_equal BigDecimal("100.00"), settlement.paid_amount.to_d
        assert_equal BigDecimal("30.00"), settlement.cnpj_amount.to_d
        assert_equal BigDecimal("66.00"), settlement.fdic_amount.to_d
        assert_equal BigDecimal("4.00"), settlement.beneficiary_amount.to_d
        assert_equal BigDecimal("66.00"), settlement.fdic_balance_before.to_d
        assert_equal BigDecimal("0.00"), settlement.fdic_balance_after.to_d
        assert_equal "hospital-payment-shared-001", settlement.payment_reference

        assert_equal 1, result.settlement_entries.size
        entry = result.settlement_entries.first
        assert_equal anticipation_request.id, entry.anticipation_request_id
        assert_equal BigDecimal("66.00"), entry.settled_amount.to_d

        anticipation_request.reload
        assert_equal "SETTLED", anticipation_request.status
        assert anticipation_request.settled_at.present?

        bundle[:allocation].reload
        bundle[:receivable].reload
        assert_equal "SETTLED", bundle[:allocation].status
        assert_equal "SETTLED", bundle[:receivable].status

        assert_equal 1, ReceivableEvent.where(
          tenant_id: @tenant.id,
          receivable_id: bundle[:receivable].id,
          event_type: "RECEIVABLE_PAYMENT_SETTLED"
        ).count
        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "RECEIVABLE_PAYMENT_SETTLEMENT_CREATED",
          target_id: settlement.id
        ).count
      end
    end

    test "uses shared cnpj split even without anticipation and sends remainder to physician" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_shared_cnpj_physician_bundle!("shared-cnpj-2")
        result = service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "hospital-payment-shared-002"
        )

        settlement = result.settlement
        assert_equal BigDecimal("30.00"), settlement.cnpj_amount.to_d
        assert_equal BigDecimal("0.00"), settlement.fdic_amount.to_d
        assert_equal BigDecimal("70.00"), settlement.beneficiary_amount.to_d
        assert_equal 0, result.settlement_entries.size
      end
    end

    test "for supplier allocation routes fdic repayment and supplier remainder without cnpj split" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("supplier-settlement-1")
        anticipation_request = create_direct_anticipation_request!(
          tenant_bundle: bundle,
          idempotency_key: "settle-supplier-1",
          requested_amount: "50.00",
          discount_rate: "0.10000000",
          discount_amount: "5.00",
          net_amount: "45.00",
          status: "APPROVED"
        )

        result = service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "hospital-payment-supplier-001"
        )

        settlement = result.settlement
        assert_equal BigDecimal("0.00"), settlement.cnpj_amount.to_d
        assert_equal BigDecimal("55.00"), settlement.fdic_amount.to_d
        assert_equal BigDecimal("45.00"), settlement.beneficiary_amount.to_d
        assert_equal 1, result.settlement_entries.size

        anticipation_request.reload
        assert_equal "SETTLED", anticipation_request.status
      end
    end

    test "replays settlement safely for same payment_reference and payload" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("supplier-replay")

        first = service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "hospital-payment-replay-001"
        )
        second = service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: first.settlement.paid_at,
          payment_reference: "hospital-payment-replay-001"
        )

        assert_equal false, first.replayed?
        assert_equal true, second.replayed?
        assert_equal first.settlement.id, second.settlement.id
        assert_equal 1, ReceivablePaymentSettlement.where(
          tenant_id: @tenant.id,
          payment_reference: "hospital-payment-replay-001"
        ).count
        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "RECEIVABLE_PAYMENT_SETTLEMENT_REPLAYED",
          target_id: first.settlement.id
        ).count
      end
    end

    test "raises conflict when payment_reference is reused with different payload" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("supplier-conflict")

        service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.00",
          paid_at: Time.current,
          payment_reference: "hospital-payment-conflict-001"
        )

        error = assert_raises(Receivables::SettlePayment::IdempotencyConflict) do
          service.call(
            receivable_id: bundle[:receivable].id,
            receivable_allocation_id: bundle[:allocation].id,
            paid_amount: "99.99",
            paid_at: Time.current,
            payment_reference: "hospital-payment-conflict-001"
          )
        end

        assert_equal "payment_reference_reused_with_different_payload", error.code
        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "RECEIVABLE_PAYMENT_SETTLEMENT_FAILED",
          target_id: bundle[:receivable].id
        ).count
      end
    end

    test "maps ledger validation errors to deterministic settlement validation errors" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("supplier-ledger-validation")
        failing_poster = Object.new
        failing_poster.define_singleton_method(:call) do |**|
          raise Ledger::PostTransaction::ValidationError.new(
            code: "unbalanced_transaction",
            message: "transaction is unbalanced."
          )
        end

        error = nil
        with_stubbed_post_settlement(failing_poster) do
          error = assert_raises(Receivables::SettlePayment::ValidationError) do
            service.call(
              receivable_id: bundle[:receivable].id,
              receivable_allocation_id: bundle[:allocation].id,
              paid_amount: "100.00",
              paid_at: Time.current,
              payment_reference: "hospital-payment-ledger-validation-001"
            )
          end
        end

        assert_equal "unbalanced_transaction", error.code
      end
    end

    test "maps ledger idempotency conflicts to settlement idempotency conflicts" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("supplier-ledger-conflict")
        failing_poster = Object.new
        failing_poster.define_singleton_method(:call) do |**|
          raise Ledger::PostTransaction::IdempotencyConflict.new(
            code: "txn_id_reused_with_different_payload",
            message: "txn_id was already used with a different payload."
          )
        end

        error = nil
        with_stubbed_post_settlement(failing_poster) do
          error = assert_raises(Receivables::SettlePayment::IdempotencyConflict) do
            service.call(
              receivable_id: bundle[:receivable].id,
              receivable_allocation_id: bundle[:allocation].id,
              paid_amount: "100.00",
              paid_at: Time.current,
              payment_reference: "hospital-payment-ledger-conflict-001"
            )
          end
        end

        assert_equal "txn_id_reused_with_different_payload", error.code
      end
    end

    test "re-raises unexpected DB errors from ledger posting" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_supplier_bundle!("supplier-ledger-db-error")
        failing_poster = Object.new
        failing_poster.define_singleton_method(:call) do |**|
          raise ActiveRecord::StatementInvalid, "PG::UndefinedTable: relation does not exist"
        end

        with_stubbed_post_settlement(failing_poster) do
          assert_raises(ActiveRecord::StatementInvalid) do
            service.call(
              receivable_id: bundle[:receivable].id,
              receivable_allocation_id: bundle[:allocation].id,
              paid_amount: "100.00",
              paid_at: Time.current,
              payment_reference: "hospital-payment-ledger-db-error-001"
            )
          end
        end
      end
    end

    test "rounding edge keeps split amounts and clearing postings reconciled" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        bundle = create_shared_cnpj_physician_bundle!("rounding-edge")
        bundle[:allocation].update!(
          metadata: {
            "cnpj_split" => {
              "applied" => true,
              "cnpj_share_rate" => "0.33333333"
            }
          }
        )
        create_direct_anticipation_request!(
          tenant_bundle: bundle,
          idempotency_key: "settle-rounding-edge-antic-1",
          requested_amount: "25.55",
          discount_rate: "0.00000001",
          discount_amount: "0.01",
          net_amount: "25.54",
          status: "APPROVED"
        )

        result = service.call(
          receivable_id: bundle[:receivable].id,
          receivable_allocation_id: bundle[:allocation].id,
          paid_amount: "100.01",
          paid_at: Time.current,
          payment_reference: "hospital-payment-rounding-edge-001"
        )
        settlement = result.settlement
        total_split = settlement.cnpj_amount.to_d + settlement.fdic_amount.to_d + settlement.beneficiary_amount.to_d
        assert_equal settlement.paid_amount.to_d, total_split

        ledger_entries = LedgerEntry.where(
          tenant_id: @tenant.id,
          source_type: "ReceivablePaymentSettlement",
          source_id: settlement.id
        ).to_a
        clearing_debit = ledger_entries.select { |entry| entry.account_code == "clearing:settlement" && entry.entry_side == "DEBIT" }
          .sum { |entry| entry.amount.to_d }
        clearing_credit = ledger_entries.select { |entry| entry.account_code == "clearing:settlement" && entry.entry_side == "CREDIT" }
          .sum { |entry| entry.amount.to_d }
        assert_equal clearing_debit, clearing_credit
      end
    end

    private

    def service
      @service ||= Receivables::SettlePayment.new(
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
      debtor = Party.create!(
        tenant: @tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-hospital")
      )
      supplier = Party.create!(
        tenant: @tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-supplier")
      )

      kind = ReceivableKind.create!(
        tenant: @tenant,
        code: "supplier_invoice_#{suffix}",
        name: "Supplier Invoice #{suffix}",
        source_family: "SUPPLIER"
      )
      receivable = Receivable.create!(
        tenant: @tenant,
        receivable_kind: kind,
        debtor_party: debtor,
        creditor_party: supplier,
        beneficiary_party: supplier,
        external_reference: "external-#{suffix}",
        gross_amount: "100.00",
        currency: "BRL",
        performed_at: Time.current,
        due_at: 3.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: supplier,
        gross_amount: "100.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )

      {
        debtor: debtor,
        supplier: supplier,
        receivable: receivable,
        allocation: allocation
      }
    end

    def create_shared_cnpj_physician_bundle!(suffix)
      hospital = Party.create!(
        tenant: @tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-hospital")
      )
      legal_entity = Party.create!(
        tenant: @tenant,
        kind: "LEGAL_ENTITY_PJ",
        legal_name: "Clinica #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-legal-entity")
      )
      physician_one = Party.create!(
        tenant: @tenant,
        kind: "PHYSICIAN_PF",
        legal_name: "Medico Um #{suffix}",
        document_number: valid_cpf_from_seed("#{suffix}-physician-1")
      )
      physician_two = Party.create!(
        tenant: @tenant,
        kind: "PHYSICIAN_PF",
        legal_name: "Medico Dois #{suffix}",
        document_number: valid_cpf_from_seed("#{suffix}-physician-2")
      )

      PhysicianLegalEntityMembership.create!(
        tenant: @tenant,
        physician_party: physician_one,
        legal_entity_party: legal_entity,
        membership_role: "ADMIN",
        status: "ACTIVE"
      )
      PhysicianLegalEntityMembership.create!(
        tenant: @tenant,
        physician_party: physician_two,
        legal_entity_party: legal_entity,
        membership_role: "MEMBER",
        status: "ACTIVE"
      )

      kind = ReceivableKind.create!(
        tenant: @tenant,
        code: "physician_shift_#{suffix}",
        name: "Physician Shift #{suffix}",
        source_family: "PHYSICIAN"
      )
      receivable = Receivable.create!(
        tenant: @tenant,
        receivable_kind: kind,
        debtor_party: hospital,
        creditor_party: legal_entity,
        beneficiary_party: legal_entity,
        external_reference: "external-#{suffix}",
        gross_amount: "100.00",
        currency: "BRL",
        performed_at: Time.current,
        due_at: 3.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: legal_entity,
        physician_party: physician_one,
        gross_amount: "100.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )

      {
        hospital: hospital,
        legal_entity: legal_entity,
        physician_one: physician_one,
        physician_two: physician_two,
        receivable: receivable,
        allocation: allocation
      }
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

    def with_stubbed_post_settlement(poster)
      singleton = Ledger::PostSettlement.singleton_class
      original_new = Ledger::PostSettlement.method(:new)
      singleton.send(:define_method, :new) { |*| poster }
      yield
    ensure
      singleton.send(:define_method, :new, original_new)
    end
  end
end
