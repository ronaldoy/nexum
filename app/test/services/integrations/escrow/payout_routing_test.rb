require "test_helper"

module Integrations
  module Escrow
    class PayoutRoutingTest < ActiveSupport::TestCase
      setup do
        @tenant = tenants(:default)
      end

      test "routes shared cnpj settlement from legal entity workspace to physician payout account" do
        with_tenant_db_context(tenant_id: @tenant.id) do
          bundle = create_shared_cnpj_bundle!("routing-shared-cnpj")
          settlement = ReceivablePaymentSettlement.create!(
            tenant: @tenant,
            receivable: bundle[:receivable],
            receivable_allocation: bundle[:allocation],
            paid_amount: "100.00",
            cnpj_amount: "30.00",
            fidc_amount: "0.00",
            beneficiary_amount: "70.00",
            fidc_balance_before: "0.00",
            fidc_balance_after: "0.00",
            paid_at: Time.current,
            payment_reference: "hospital-payment-routing-shared",
            idempotency_key: "idem-routing-shared",
            request_id: SecureRandom.uuid,
            metadata: {}
          )

          route = PayoutRouting.new(tenant_id: @tenant.id).call(payload: {}, settlement: settlement)

          assert_equal bundle[:legal_entity].id, route.source_party.id
          assert_equal bundle[:physician].id, route.recipient_party.id
          assert_equal "LEGAL_ENTITY_RETENTION_SPLIT", route.payout_model
          assert_equal bundle[:legal_entity].id, route.retention_party.id
          assert_equal BigDecimal("30.00"), route.retention_amount.to_d
          assert_equal BigDecimal("0.30000000"), route.retention_rate.to_d
        end
      end

      test "routes direct supplier settlement from supplier workspace to supplier payout account" do
        with_tenant_db_context(tenant_id: @tenant.id) do
          bundle = create_supplier_bundle!("routing-supplier")
          settlement = ReceivablePaymentSettlement.create!(
            tenant: @tenant,
            receivable: bundle[:receivable],
            receivable_allocation: bundle[:allocation],
            paid_amount: "100.00",
            cnpj_amount: "0.00",
            fidc_amount: "10.00",
            beneficiary_amount: "90.00",
            fidc_balance_before: "10.00",
            fidc_balance_after: "0.00",
            paid_at: Time.current,
            payment_reference: "hospital-payment-routing-supplier",
            idempotency_key: "idem-routing-supplier",
            request_id: SecureRandom.uuid,
            metadata: {}
          )

          route = PayoutRouting.new(tenant_id: @tenant.id).call(payload: {}, settlement: settlement)

          assert_equal bundle[:supplier].id, route.source_party.id
          assert_equal bundle[:supplier].id, route.recipient_party.id
          assert_equal "ENTITY_DIRECT", route.payout_model
          assert_nil route.retention_party
          assert_equal BigDecimal("0"), route.retention_amount.to_d
        end
      end

      private

      def create_shared_cnpj_bundle!(suffix)
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
        physician = Party.create!(
          tenant: @tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Medico #{suffix}",
          document_number: valid_cpf_from_seed("#{suffix}-physician")
        )

        PhysicianLegalEntityMembership.create!(
          tenant: @tenant,
          physician_party: physician,
          legal_entity_party: legal_entity,
          membership_role: "ADMIN",
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
          physician_party: physician,
          gross_amount: "100.00",
          tax_reserve_amount: "30.00",
          status: "OPEN"
        )

        {
          receivable: receivable,
          allocation: allocation,
          legal_entity: legal_entity,
          physician: physician
        }
      end

      def create_supplier_bundle!(suffix)
        hospital = Party.create!(
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
          debtor_party: hospital,
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
          receivable: receivable,
          allocation: allocation,
          supplier: supplier
        }
      end
    end
  end
end
