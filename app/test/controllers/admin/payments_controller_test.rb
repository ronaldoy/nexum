require "test_helper"

module Admin
  class PaymentsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @ops_user = users(:one)
      @dead_letter_payment_instruction_event_id = nil

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
        create_payments_dashboard_sample_data!
      end
    end

    test "ops admin can view the payments dashboard" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_payments_path

      assert_response :success
      assert_includes response.body, "Painel de pagamentos"
      assert_includes response.body, "Operação Stark Bank"
      assert_includes response.body, @tenant.slug
      assert_includes response.body, "Fila pendente"
      assert_includes response.body, "Lotes de dispatch"
      assert_includes response.body, "Fornecedor Pagamento Pendente"
      assert_includes response.body, "Fornecedor Pagamento Falho"
      assert_includes response.body, "Taxa Stark"
      assert_includes response.body, "R$ 2,50"
      assert_includes response.body, "workspace-default-source"
      assert_includes response.body, "Eventos de instrução PIX"
      assert_includes response.body, "Backlog vencido"
      assert_includes response.body, "Sync hospital API"
      assert_includes response.body, "Reenfileirar"
    end

    test "status filter narrows the payout rows" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      get admin_payments_path(status: "failed")

      assert_response :success
      assert_includes response.body, "Fornecedor Pagamento Falho"
      refute_includes response.body, "Fornecedor Pagamento Pendente"
      assert_includes response.body, "status=failed"
      assert_includes response.body, "Exibindo"
    end

    test "ops admin can replay a dead-letter payment instruction event" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      assert_difference("OutboxEvent.where(tenant_id: @tenant.id, event_type: 'RECEIVABLE_HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_REQUESTED').count", 1) do
        post replay_instruction_event_admin_payments_path, params: { outbox_event_id: @dead_letter_payment_instruction_event_id }
      end

      assert_redirected_to admin_payments_path(page: 1)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        replay_event = OutboxEvent.where(
          tenant_id: @tenant.id,
          event_type: "RECEIVABLE_HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_REQUESTED"
        ).where("payload ->> 'replayed_from_outbox_event_id' = ?", @dead_letter_payment_instruction_event_id).order(created_at: :desc).first

        assert replay_event.present?
        assert replay_event.idempotency_key.include?(":replay:")
        assert_equal @dead_letter_payment_instruction_event_id, replay_event.payload.fetch("replayed_from_outbox_event_id")
        assert_equal 1, ActionIpLog.where(
          tenant_id: @tenant.id,
          action_type: "PAYMENT_INSTRUCTION_EVENT_REPLAY_REQUESTED",
          target_type: "OutboxEvent",
          target_id: replay_event.id
        ).count
      end
    end

    private

    def create_payments_dashboard_sample_data!
      batch = EscrowPayoutBatch.create!(
        tenant: @tenant,
        provider: "STARKBANK",
        status: "OPEN",
        source_provider_account_id: "workspace-default-source",
        risk_limit_amount: "100000.00",
        balance_snapshot_amount: "100000.00",
        reserved_amount: "0.00",
        dispatched_amount: "1250.00",
        fee_amount: "2.50",
        started_at: Time.zone.parse("2026-03-12 10:00:00"),
        last_polled_at: Time.zone.parse("2026-03-12 10:05:00"),
        metadata: {}
      )

      create_payout_record!(
        suffix: "pending",
        party_name: "Fornecedor Pagamento Pendente",
        payout_status: "PENDING",
        provider_status: "created",
        amount: "950.00",
        fee_amount: "0.00",
        batch: batch
      )

      create_payout_record!(
        suffix: "failed",
        party_name: "Fornecedor Pagamento Falho",
        payout_status: "FAILED",
        provider_status: "failed",
        amount: "300.00",
        fee_amount: "2.50",
        batch: batch,
        confirmed_at: nil,
        last_error_code: "starkbank_transfer_failed",
        last_error_message: "Stark Bank PIX transfer failed."
      )

      create_stale_payment_instruction_event!(
        event_type: "RECEIVABLE_ESCROW_PAYMENT_INSTRUCTIONS_REFRESH_REQUESTED",
        idempotency_key: "payment-instruction-refresh-stale-001",
        created_at: Time.zone.parse("2026-03-12 08:00:00")
      )
      @dead_letter_payment_instruction_event_id = create_dead_letter_payment_instruction_event!(
        event_type: "RECEIVABLE_HOSPITAL_PAYMENT_INSTRUCTIONS_SYNC_REQUESTED",
        idempotency_key: "payment-instruction-hospital-dead-letter-001",
        created_at: Time.zone.parse("2026-03-12 09:00:00"),
        error_code: "hospital_api_unreachable",
        error_message: "Hospital API endpoint is unreachable."
      )
    end

    def create_payout_record!(suffix:, party_name:, payout_status:, provider_status:, amount:, fee_amount:, batch:, confirmed_at: nil, last_error_code: nil, last_error_message: nil)
      hospital = Party.create!(
        tenant: @tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital #{suffix}",
        document_number: valid_cnpj_from_seed("#{suffix}-hospital-payments")
      )
      supplier = Party.create!(
        tenant: @tenant,
        kind: "SUPPLIER",
        legal_name: party_name,
        document_number: valid_cnpj_from_seed("#{suffix}-supplier-payments")
      )
      receivable_kind = ReceivableKind.create!(
        tenant: @tenant,
        code: "supplier_invoice_payments_#{suffix}",
        name: "Supplier Invoice Payments #{suffix}",
        source_family: "SUPPLIER"
      )
      receivable = Receivable.create!(
        tenant: @tenant,
        receivable_kind: receivable_kind,
        debtor_party: hospital,
        creditor_party: supplier,
        beneficiary_party: supplier,
        external_reference: "RCV-PAY-#{suffix.upcase}",
        gross_amount: "1000.00",
        currency: "BRL",
        status: "PERFORMED",
        performed_at: Time.zone.parse("2026-03-10 09:00:00"),
        due_at: 5.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(Date.new(2026, 3, 10))
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: supplier,
        gross_amount: "1000.00",
        tax_reserve_amount: "0.00",
        status: "OPEN"
      )
      settlement = ReceivablePaymentSettlement.create!(
        tenant: @tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        paid_amount: "1000.00",
        cnpj_amount: "0.00",
        fidc_amount: "50.00",
        beneficiary_amount: "950.00",
        fidc_balance_before: "50.00",
        fidc_balance_after: "0.00",
        paid_at: Time.zone.parse("2026-03-11 14:00:00"),
        payment_reference: "payment-ref-#{suffix}",
        idempotency_key: "settlement-#{suffix}",
        request_id: SecureRandom.uuid,
        metadata: {}
      )
      escrow_account = EscrowAccount.create!(
        tenant: @tenant,
        party: supplier,
        provider: "STARKBANK",
        account_type: "ESCROW",
        status: "ACTIVE",
        provider_account_id: "workspace-#{suffix}",
        provider_request_id: "workspace-request-#{suffix}",
        last_synced_at: Time.current,
        metadata: {}
      )

      EscrowPayout.create!(
        tenant: @tenant,
        receivable_payment_settlement: settlement,
        party: supplier,
        escrow_account: escrow_account,
        escrow_payout_batch: batch,
        provider: "STARKBANK",
        status: payout_status,
        provider_status: provider_status,
        amount: amount,
        currency: "BRL",
        idempotency_key: "payout-#{suffix}",
        provider_transfer_id: "provider-transfer-#{suffix}",
        provider_fee_amount: fee_amount,
        provider_fee_currency: "BRL",
        provider_source_account_id: batch.source_provider_account_id,
        provider_destination_account_id: escrow_account.provider_account_id,
        requested_at: Time.zone.parse("2026-03-11 14:05:00"),
        processed_at: (payout_status == "FAILED" ? Time.zone.parse("2026-03-11 14:10:00") : nil),
        confirmed_at: confirmed_at,
        last_error_code: last_error_code,
        last_error_message: last_error_message,
        metadata: {}
      )
    end

    def create_stale_payment_instruction_event!(event_type:, idempotency_key:, created_at:)
      insert_outbox_event!(
        event_type: event_type,
        idempotency_key: idempotency_key,
        created_at: created_at,
        payload: {
          "receivable_id" => SecureRandom.uuid,
          "receivable_allocation_id" => SecureRandom.uuid,
          "operational_party_id" => SecureRandom.uuid,
          "provider" => "STARKBANK",
          "payment_instruction_idempotency_key" => "party-123:escrow_account"
        }
      )
    end

    def create_dead_letter_payment_instruction_event!(event_type:, idempotency_key:, created_at:, error_code:, error_message:)
      event_id = insert_outbox_event!(
        event_type: event_type,
        idempotency_key: idempotency_key,
        created_at: created_at,
        payload: {
          "receivable_id" => SecureRandom.uuid,
          "receivable_allocation_id" => SecureRandom.uuid,
          "hospital_party_id" => SecureRandom.uuid,
          "operational_party_id" => SecureRandom.uuid,
          "provider" => "STARKBANK",
          "payment_instruction_idempotency_key" => "party-456:escrow_account",
          "hospital_sync_idempotency_key" => idempotency_key
        }
      )

      OutboxDispatchAttempt.create!(
        tenant: @tenant,
        outbox_event_id: event_id,
        attempt_number: 1,
        status: "DEAD_LETTER",
        error_code: error_code,
        error_message: error_message,
        occurred_at: created_at + 5.minutes
      )

      event_id
    end

    def insert_outbox_event!(event_type:, idempotency_key:, created_at:, payload:)
      connection = ActiveRecord::Base.connection
      event_id = SecureRandom.uuid
      normalized_payload = payload.deep_stringify_keys
      normalized_payload["payload_hash"] = CanonicalJson.digest(normalized_payload)

      connection.execute(<<~SQL)
        INSERT INTO outbox_events (
          id, tenant_id, aggregate_type, aggregate_id, event_type, status, attempts, idempotency_key, payload, created_at, updated_at
        ) VALUES (
          #{connection.quote(event_id)},
          #{connection.quote(@tenant.id)},
          'Receivable',
          #{connection.quote(SecureRandom.uuid)},
          #{connection.quote(event_type)},
          'PENDING',
          0,
          #{connection.quote(idempotency_key)},
          #{connection.quote(JSON.generate(normalized_payload))}::jsonb,
          #{connection.quote(created_at)},
          #{connection.quote(created_at)}
        )
      SQL

      event_id
    end
  end
end
