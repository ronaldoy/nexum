require "test_helper"

module Integrations
  module Escrow
    class DispatchPayoutTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @tenant = tenants(:default)
        @user = users(:one)
        clear_enqueued_jobs
        clear_performed_jobs
      end

      test "dispatches payout and persists escrow account and sent payout" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-success")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-success",
            cnpj_amount: "0.00",
            fidc_amount: "5.00",
            beneficiary_amount: "95.00"
          )
          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-success"
          )

          fake_provider = FakeProviderSuccess.new
          payout = nil

          with_stubbed_provider(fake_provider) do
            payout = Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
          end

          assert_equal "SENT", payout.status
          assert_equal "provider-transfer-123", payout.provider_transfer_id
          assert_equal BigDecimal("95.00"), payout.amount.to_d
          assert_equal 1, fake_provider.open_account_calls.size
          assert_equal 1, fake_provider.create_payout_calls.size

          account = EscrowAccount.find_by!(tenant_id: @tenant.id, party_id: bundle[:supplier].id, provider: "QITECH")
          assert_equal "ACTIVE", account.status
          assert_equal "provider-account-123", account.provider_account_id
          assert_equal payout.escrow_account_id, account.id

          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "ESCROW_PAYOUT_DISPATCHED",
            target_type: "EscrowPayout",
            target_id: payout.id
          ).count
        end
      end

      test "returns existing sent payout without dispatching provider again" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-replay")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-replay",
            cnpj_amount: "0.00",
            fidc_amount: "5.00",
            beneficiary_amount: "95.00"
          )

          account = EscrowAccount.create!(
            tenant: @tenant,
            party: bundle[:supplier],
            provider: "QITECH",
            account_type: "ESCROW",
            status: "ACTIVE",
            provider_account_id: "provider-account-replay",
            provider_request_id: "provider-request-replay",
            last_synced_at: Time.current,
            metadata: {}
          )

          existing_payout = EscrowPayout.create!(
            tenant: @tenant,
            receivable_payment_settlement: settlement,
            party: bundle[:supplier],
            escrow_account: account,
            provider: "QITECH",
            status: "SENT",
            amount: "95.00",
            currency: "BRL",
            idempotency_key: "idem-dispatch-payout-replay",
            provider_transfer_id: "provider-transfer-replay",
            requested_at: Time.current,
            processed_at: Time.current,
            metadata: {}
          )

          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-replay"
          )

          returned = nil
          with_stubbed_provider(FakeProviderShouldNotBeCalled.new) do
            returned = Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
          end

          assert_equal existing_payout.id, returned.id
          assert_equal "SENT", returned.status
          assert_equal 1, EscrowPayout.where(tenant_id: @tenant.id, idempotency_key: "idem-dispatch-payout-replay").count
          assert_equal 0, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "ESCROW_PAYOUT_DISPATCHED",
            target_type: "EscrowPayout",
            target_id: existing_payout.id
          ).count
        end
      end

      test "persists payout failure and logs when provider create payout fails" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-failure")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-failure",
            cnpj_amount: "0.00",
            fidc_amount: "5.00",
            beneficiary_amount: "95.00"
          )
          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-failure"
          )

          error = nil
          with_stubbed_provider(FakeProviderFailure.new) do
            error = assert_raises(Integrations::Escrow::RemoteError) do
              Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
            end
          end

          assert_equal "qitech_timeout", error.code

          payout = EscrowPayout.find_by!(tenant_id: @tenant.id, idempotency_key: "idem-dispatch-payout-failure")
          assert_equal "FAILED", payout.status
          assert_equal "qitech_timeout", payout.last_error_code
          assert_equal "Provider timeout.", payout.last_error_message

          assert_equal 1, ActionIpLog.where(
            tenant_id: @tenant.id,
            action_type: "ESCROW_PAYOUT_DISPATCH_FAILED",
            target_type: "EscrowPayout",
            target_id: payout.id
          ).count
        end
      end

      test "rejects excess payout amount that differs from settlement beneficiary amount" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-mismatch")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-mismatch",
            cnpj_amount: "0.00",
            fidc_amount: "5.00",
            beneficiary_amount: "95.00"
          )
          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-mismatch",
            amount: "94.99"
          )

          error = assert_raises(Integrations::Escrow::ValidationError) do
            Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
          end

          assert_equal "escrow_excess_amount_mismatch", error.code
          assert_nil EscrowPayout.find_by(tenant_id: @tenant.id, idempotency_key: "idem-dispatch-payout-mismatch")
        end
      end

      test "persists processing payout and schedules a status sync" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-processing")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-processing",
            cnpj_amount: "0.00",
            fidc_amount: "5.00",
            beneficiary_amount: "95.00"
          )
          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-processing",
            provider: "STARKBANK"
          )

          payout = nil
          batch = EscrowPayoutBatch.create!(
            tenant: @tenant,
            provider: "STARKBANK",
            status: "OPEN",
            source_provider_account_id: "source-workspace-123",
            risk_limit_amount: "100000.00",
            balance_snapshot_amount: "100000.00",
            reserved_amount: "0.00",
            dispatched_amount: "0.00",
            fee_amount: "0.00",
            started_at: Time.current,
            last_polled_at: Time.current,
            metadata: {}
          )

          with_environment("ESCROW_ENABLE_STARKBANK" => "true") do
            with_stubbed_provider(FakeProviderProcessing.new(batch_id: batch.id)) do
              assert_difference("enqueued_jobs.size", 1) do
                payout = Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
              end
            end
          end

          assert_equal "PROCESSING", payout.status
          assert_equal "created", payout.provider_status
          assert_equal BigDecimal("1.25"), payout.provider_fee_amount.to_d
          assert_equal "source-workspace-123", payout.provider_source_account_id
          assert_equal "destination-workspace-123", payout.provider_destination_account_id
          assert_equal batch.id, payout.escrow_payout_batch_id
          assert_nil payout.processed_at

          enqueued_job = enqueued_jobs.last
          assert_equal Integrations::Escrow::SyncPayoutStatusJob, enqueued_job[:job]
          assert_equal @tenant.id, enqueued_job[:args].first["tenant_id"]
          assert_equal payout.id, enqueued_job[:args].first["payout_id"]
        end
      end

      test "keeps payout pending when starkbank dispatch budget is exhausted" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_supplier_bundle!("dispatch-payout-budget")
          settlement = create_settlement!(
            bundle: bundle,
            suffix: "dispatch-payout-budget",
            cnpj_amount: "0.00",
            fidc_amount: "5.00",
            beneficiary_amount: "95.00"
          )
          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:supplier],
            idempotency_key: "idem-dispatch-payout-budget",
            provider: "STARKBANK"
          )

          error = nil

          with_environment("ESCROW_ENABLE_STARKBANK" => "true") do
            with_stubbed_provider(FakeProviderInsufficientBudget.new) do
              error = assert_raises(Integrations::Escrow::ValidationError) do
                Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
              end
            end
          end

          assert_equal "starkbank_insufficient_dispatch_budget", error.code

          payout = EscrowPayout.find_by!(tenant_id: @tenant.id, idempotency_key: "idem-dispatch-payout-budget")
          assert_equal "PENDING", payout.status
          assert_equal "starkbank_insufficient_dispatch_budget", payout.last_error_code
          assert_equal "Dispatch budget exhausted.", payout.last_error_message
        end
      end

      test "uses the legal entity operational account as payout source for shared cnpj settlements" do
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
          bundle = create_shared_cnpj_bundle!("dispatch-payout-shared-cnpj")
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
            payment_reference: "hospital-payment-shared-cnpj",
            idempotency_key: "idem-settlement-shared-cnpj",
            request_id: SecureRandom.uuid,
            metadata: {}
          )
          outbox_event = create_escrow_outbox_event!(
            settlement: settlement,
            recipient_party: bundle[:physician],
            idempotency_key: "idem-dispatch-payout-shared-cnpj",
            source_party: bundle[:legal_entity]
          )

          fake_provider = FakeProviderSuccess.new
          payout = nil

          with_stubbed_provider(fake_provider) do
            payout = Integrations::Escrow::DispatchPayout.new.call(outbox_event: outbox_event)
          end

          source_account = EscrowAccount.find_by!(tenant_id: @tenant.id, party_id: bundle[:legal_entity].id, provider: "QITECH")
          assert_equal source_account.id, payout.escrow_account_id
          assert_equal bundle[:physician].id, payout.party_id
          assert_equal bundle[:legal_entity].id, fake_provider.open_account_calls.last[:party_id]
          assert_equal bundle[:physician].id, fake_provider.create_payout_calls.last[:recipient_party_id]
          assert_equal source_account.id, fake_provider.create_payout_calls.last[:escrow_account_id]
          assert_equal "LEGAL_ENTITY_RETENTION_SPLIT", payout.metadata.dig("payload", "distribution_model", "payout_model")
        end
      end

      private

      def create_escrow_outbox_event!(settlement:, recipient_party:, idempotency_key:, amount: nil, provider: "QITECH", source_party: nil)
        payload_amount = amount || settlement.beneficiary_amount.to_d.to_s("F")
        payout_model = if source_party.present? && source_party.id != recipient_party.id
          "LEGAL_ENTITY_RETENTION_SPLIT"
        else
          "ENTITY_DIRECT"
        end

        OutboxEvent.create!(
          tenant: @tenant,
          aggregate_type: "ReceivablePaymentSettlement",
          aggregate_id: settlement.id,
          event_type: "RECEIVABLE_ESCROW_EXCESS_PAYOUT_REQUESTED",
          status: "PENDING",
          idempotency_key: idempotency_key,
          payload: {
            "settlement_id" => settlement.id,
            "receivable_id" => settlement.receivable_id,
            "source_party_id" => source_party&.id || recipient_party.id,
            "recipient_party_id" => recipient_party.id,
            "amount" => payload_amount,
            "currency" => "BRL",
            "provider" => provider,
            "payout_kind" => "EXCESS",
            "payout_idempotency_key" => idempotency_key,
            "account_idempotency_key" => "#{source_party&.id || recipient_party.id}:escrow_account",
            "provider_request_control_key" => idempotency_key,
            "distribution_model" => {
              "payout_model" => payout_model,
              "source_party_id" => source_party&.id || recipient_party.id,
              "recipient_party_id" => recipient_party.id
            }
          }
        )
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
          due_at: 5.days.from_now,
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
          due_at: 5.days.from_now,
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

      def create_settlement!(bundle:, suffix:, cnpj_amount:, fidc_amount:, beneficiary_amount:)
        ReceivablePaymentSettlement.create!(
          tenant: @tenant,
          receivable: bundle[:receivable],
          receivable_allocation: bundle[:allocation],
          paid_amount: "100.00",
          cnpj_amount: cnpj_amount,
          fidc_amount: fidc_amount,
          beneficiary_amount: beneficiary_amount,
          fidc_balance_before: fidc_amount,
          fidc_balance_after: "0.00",
          paid_at: Time.current,
          payment_reference: "hospital-payment-#{suffix}",
          idempotency_key: "idem-settlement-#{suffix}",
          request_id: SecureRandom.uuid,
          metadata: {}
        )
      end

      def with_stubbed_provider(provider)
        singleton = Integrations::Escrow::ProviderRegistry.singleton_class
        original_fetch = Integrations::Escrow::ProviderRegistry.method(:fetch)
        singleton.send(:define_method, :fetch) { |provider_code:, tenant_id: nil, tenant_slug: nil| provider }
        yield
      ensure
        singleton.send(:define_method, :fetch, original_fetch)
      end

      class FakeProviderSuccess
        attr_reader :open_account_calls, :create_payout_calls

        def initialize
          @open_account_calls = []
          @create_payout_calls = []
        end

        def provider_code
          "QITECH"
        end

        def account_from_party_metadata(party:)
          nil
        end

        def open_escrow_account!(tenant_id:, party:, idempotency_key:, metadata:)
          @open_account_calls << {
            tenant_id: tenant_id,
            party_id: party.id,
            idempotency_key: idempotency_key
          }
          Integrations::Escrow::AccountProvisionResult.new(
            provider_account_id: "provider-account-123",
            provider_request_id: "provider-request-123",
            status: "ACTIVE",
            metadata: {
              "account_info" => {
                "branch_number" => "0001",
                "account_number" => "12345678",
                "account_digit" => "9",
                "account_type" => "payment_account"
              }
            }
          )
        end

        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          @create_payout_calls << {
            tenant_id: tenant_id,
            escrow_account_id: escrow_account.id,
            recipient_party_id: recipient_party.id,
            amount: amount,
            currency: currency,
            idempotency_key: idempotency_key
          }
          Integrations::Escrow::PayoutResult.new(
            provider_transfer_id: "provider-transfer-123",
            status: "SENT",
            metadata: { "status" => "SENT" }
          )
        end
      end

      class FakeProviderShouldNotBeCalled < FakeProviderSuccess
        def open_escrow_account!(tenant_id:, party:, idempotency_key:, metadata:)
          raise "open_escrow_account! should not be called for sent payout replay"
        end

        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          raise "create_payout! should not be called for sent payout replay"
        end
      end

      class FakeProviderFailure < FakeProviderSuccess
        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          raise Integrations::Escrow::RemoteError.new(
            code: "qitech_timeout",
            message: "Provider timeout.",
            http_status: 504
          )
        end
      end

      class FakeProviderProcessing < FakeProviderSuccess
        def initialize(batch_id:)
          super()
          @batch_id = batch_id
        end

        def provider_code
          "STARKBANK"
        end

        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          @create_payout_calls << {
            tenant_id: tenant_id,
            escrow_account_id: escrow_account.id,
            recipient_party_id: recipient_party.id,
            amount: amount,
            currency: currency,
            idempotency_key: idempotency_key
          }
          Integrations::Escrow::PayoutResult.new(
            provider_transfer_id: "provider-transfer-processing",
            status: "PROCESSING",
            provider_status: "created",
            provider_fee_amount: BigDecimal("1.25"),
            provider_fee_currency: "BRL",
            provider_source_account_id: "source-workspace-123",
            provider_destination_account_id: "destination-workspace-123",
            batch_id: @batch_id,
            metadata: { "status" => "created" }
          )
        end
      end

      class FakeProviderInsufficientBudget < FakeProviderProcessing
        def initialize
          super(batch_id: nil)
        end

        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          raise Integrations::Escrow::ValidationError.new(
            code: "starkbank_insufficient_dispatch_budget",
            message: "Dispatch budget exhausted."
          )
        end
      end

      def with_environment(overrides)
        previous = {}
        overrides.each do |key, value|
          previous[key] = ENV[key]
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
        yield
      ensure
        previous.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
      end
    end
  end
end
