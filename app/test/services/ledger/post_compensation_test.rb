require "test_helper"

module Ledger
  class PostCompensationTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @request_id = SecureRandom.uuid
    end

    test "creates compensating entries with opposite sides and preserved amounts" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        original_txn_id = SecureRandom.uuid
        source_id = SecureRandom.uuid

        PostTransaction.new(tenant_id: @tenant.id, request_id: @request_id).call(
          txn_id: original_txn_id,
          posted_at: Time.current,
          source_type: "ManualAdjustment",
          source_id: source_id,
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: "25.00" },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: "25.00" }
          ]
        )

        compensation_txn_id = SecureRandom.uuid
        result = service.call(
          original_txn_id: original_txn_id,
          compensation_txn_id: compensation_txn_id,
          compensation_reference: "comp-ref-001",
          posted_at: Time.current,
          source_type: "ManualCompensation",
          source_id: SecureRandom.uuid,
          reason: "operator_correction",
          metadata: { "channel" => "ops_backoffice" }
        )

        assert_equal 2, result.size
        assert_equal compensation_txn_id, result.first.txn_id

        original = LedgerEntry.where(tenant_id: @tenant.id, txn_id: original_txn_id).order(:entry_position).to_a
        compensation = LedgerEntry.where(tenant_id: @tenant.id, txn_id: compensation_txn_id).order(:entry_position).to_a

        assert_equal original.size, compensation.size
        original.zip(compensation).each do |original_entry, compensating_entry|
          expected_side = original_entry.entry_side == "DEBIT" ? "CREDIT" : "DEBIT"
          assert_equal expected_side, compensating_entry.entry_side
          assert_equal original_entry.account_code, compensating_entry.account_code
          assert_equal original_entry.amount.to_d, compensating_entry.amount.to_d
          assert_equal original_entry.party_id.to_s, compensating_entry.party_id.to_s
          assert_equal original_txn_id, compensating_entry.metadata.dig("compensation", "original_txn_id")
          assert_equal "operator_correction", compensating_entry.metadata.dig("compensation", "reason")
          assert_equal "comp-ref-001", compensating_entry.metadata.dig("compensation", "compensation_reference")
          assert compensating_entry.metadata.dig("compensation", "audit_action_log_id").present?
          assert_equal "COMPENSATION:comp-ref-001", compensating_entry.payment_reference
        end

        assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "LEDGER_COMPENSATION_REQUESTED", target_id: compensation_txn_id).count
        assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "LEDGER_COMPENSATION_POSTED", target_id: compensation_txn_id).count
      end
    end

    test "is idempotent for same compensation txn_id" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        original_txn_id = SecureRandom.uuid
        PostTransaction.new(tenant_id: @tenant.id, request_id: @request_id).call(
          txn_id: original_txn_id,
          posted_at: Time.current,
          source_type: "ManualAdjustment",
          source_id: SecureRandom.uuid,
          entries: [
            { account_code: "clearing:settlement", entry_side: "DEBIT", amount: "10.00" },
            { account_code: "receivables:hospital", entry_side: "CREDIT", amount: "10.00" }
          ]
        )

        compensation_txn_id = SecureRandom.uuid
        source_id = SecureRandom.uuid
        first = service.call(
          original_txn_id: original_txn_id,
          compensation_txn_id: compensation_txn_id,
          compensation_reference: "comp-ref-002",
          posted_at: Time.current,
          source_type: "ManualCompensation",
          source_id: source_id,
          reason: "operator_correction"
        )
        second = service.call(
          original_txn_id: original_txn_id,
          compensation_txn_id: compensation_txn_id,
          compensation_reference: "comp-ref-002",
          posted_at: Time.current,
          source_type: "ManualCompensation",
          source_id: source_id,
          reason: "operator_correction"
        )

        assert_equal first.map(&:id), second.map(&:id)
      end
    end

    test "raises when original transaction does not exist" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        error = assert_raises(Ledger::PostCompensation::ValidationError) do
          service.call(
            original_txn_id: SecureRandom.uuid,
            compensation_txn_id: SecureRandom.uuid,
            compensation_reference: "comp-ref-003",
            posted_at: Time.current,
            source_type: "ManualCompensation",
            source_id: SecureRandom.uuid,
            reason: "operator_correction"
          )
        end

        assert_equal "original_transaction_not_found", error.code
        assert_equal 1, ActionIpLog.where(tenant_id: @tenant.id, action_type: "LEDGER_COMPENSATION_FAILED").count
      end
    end

    test "requires compensation reference" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        original_txn_id = create_original_transaction!

        error = assert_raises(Ledger::PostCompensation::ValidationError) do
          service.call(
            original_txn_id: original_txn_id,
            compensation_txn_id: SecureRandom.uuid,
            compensation_reference: "",
            posted_at: Time.current,
            source_type: "ManualCompensation",
            source_id: SecureRandom.uuid,
            reason: "operator_correction"
          )
        end

        assert_equal "compensation_reference_required", error.code
      end
    end

    test "requires source_type" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        original_txn_id = create_original_transaction!

        error = assert_raises(Ledger::PostCompensation::ValidationError) do
          service.call(
            original_txn_id: original_txn_id,
            compensation_txn_id: SecureRandom.uuid,
            compensation_reference: "comp-ref-004",
            posted_at: Time.current,
            source_type: "",
            source_id: SecureRandom.uuid,
            reason: "operator_correction"
          )
        end

        assert_equal "source_type_required", error.code
      end
    end

    test "requires source_id" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        original_txn_id = create_original_transaction!

        error = assert_raises(Ledger::PostCompensation::ValidationError) do
          service.call(
            original_txn_id: original_txn_id,
            compensation_txn_id: SecureRandom.uuid,
            compensation_reference: "comp-ref-005",
            posted_at: Time.current,
            source_type: "ManualCompensation",
            source_id: "",
            reason: "operator_correction"
          )
        end

        assert_equal "source_id_required", error.code
      end
    end

    test "requires posted_at" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        original_txn_id = create_original_transaction!

        error = assert_raises(Ledger::PostCompensation::ValidationError) do
          service.call(
            original_txn_id: original_txn_id,
            compensation_txn_id: SecureRandom.uuid,
            compensation_reference: "comp-ref-006",
            posted_at: nil,
            source_type: "ManualCompensation",
            source_id: SecureRandom.uuid,
            reason: "operator_correction"
          )
        end

        assert_equal "posted_at_required", error.code
      end
    end

    test "requires valid posted_at" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        original_txn_id = create_original_transaction!

        error = assert_raises(Ledger::PostCompensation::ValidationError) do
          service.call(
            original_txn_id: original_txn_id,
            compensation_txn_id: SecureRandom.uuid,
            compensation_reference: "comp-ref-007",
            posted_at: "not-a-time",
            source_type: "ManualCompensation",
            source_id: SecureRandom.uuid,
            reason: "operator_correction"
          )
        end

        assert_equal "invalid_posted_at", error.code
      end
    end

    test "raises explicit audit error when action log write fails" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
        original_txn_id = create_original_transaction!

        error = assert_raises(Ledger::PostCompensation::AuditLogError) do
          singleton = ActionIpLog.singleton_class
          original_create = ActionIpLog.method(:create!)
          singleton.send(:define_method, :create!) { |*_, **_kwargs| raise ActiveRecord::RecordInvalid.new(ActionIpLog.new) }

          begin
            service.call(
              original_txn_id: original_txn_id,
              compensation_txn_id: SecureRandom.uuid,
              compensation_reference: "comp-ref-008",
              posted_at: Time.current,
              source_type: "ManualCompensation",
              source_id: SecureRandom.uuid,
              reason: "operator_correction"
            )
          ensure
            singleton.send(:define_method, :create!, original_create)
          end
        end

        assert_equal "audit_log_write_failed", error.code
      end
    end

    private

    def service
      @service ||= Ledger::PostCompensation.new(
        tenant_id: @tenant.id,
        request_id: @request_id,
        request_ip: "127.0.0.1",
        user_agent: "rails-test",
        endpoint_path: "/api/v1/ledger/compensations",
        http_method: "POST",
        actor_party_id: nil,
        channel: "ADMIN"
      )
    end

    def create_original_transaction!
      original_txn_id = SecureRandom.uuid
      PostTransaction.new(tenant_id: @tenant.id, request_id: @request_id).call(
        txn_id: original_txn_id,
        posted_at: Time.current,
        source_type: "ManualAdjustment",
        source_id: SecureRandom.uuid,
        entries: [
          { account_code: "clearing:settlement", entry_side: "DEBIT", amount: "10.00" },
          { account_code: "receivables:hospital", entry_side: "CREDIT", amount: "10.00" }
        ]
      )
      original_txn_id
    end
  end
end
