require "test_helper"

module Integrations
  module Escrow
    module StarkBank
      class AllocateBatchTest < ActiveSupport::TestCase
        setup do
          @tenant = tenants(:default)
          @user = users(:one)
        end

        test "reserves dispatch capacity as soon as a batch is allocated" do
          with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
            batch = AllocateBatch.new(
              tenant_id: @tenant.id,
              provider: "STARKBANK",
              source_provider_account_id: "workspace-source",
              amount: BigDecimal("60.00"),
              risk_limit_amount: BigDecimal("100.00"),
              balance_amount: BigDecimal("100.00")
            ).call

            batch.reload
            assert_equal "OPEN", batch.status
            assert_equal BigDecimal("60.00"), batch.reserved_amount.to_d
            assert_equal BigDecimal("0.00"), batch.dispatched_amount.to_d
            assert_equal BigDecimal("40.00"), batch.remaining_capacity
            assert_equal BigDecimal("40.00"), batch.available_snapshot_budget
          end
        end

        test "does not overcommit an open batch after capacity is reserved" do
          with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "worker") do
            first_batch = AllocateBatch.new(
              tenant_id: @tenant.id,
              provider: "STARKBANK",
              source_provider_account_id: "workspace-source",
              amount: BigDecimal("60.00"),
              risk_limit_amount: BigDecimal("100.00"),
              balance_amount: BigDecimal("100.00")
            ).call

            same_batch = AllocateBatch.new(
              tenant_id: @tenant.id,
              provider: "STARKBANK",
              source_provider_account_id: "workspace-source",
              amount: BigDecimal("30.00"),
              risk_limit_amount: BigDecimal("100.00"),
              balance_amount: BigDecimal("100.00")
            ).call

            next_batch = AllocateBatch.new(
              tenant_id: @tenant.id,
              provider: "STARKBANK",
              source_provider_account_id: "workspace-source",
              amount: BigDecimal("15.00"),
              risk_limit_amount: BigDecimal("100.00"),
              balance_amount: BigDecimal("100.00")
            ).call

            first_batch.reload
            same_batch.reload
            next_batch.reload

            assert_equal first_batch.id, same_batch.id
            assert_equal BigDecimal("90.00"), first_batch.reserved_amount.to_d
            assert_equal "CLOSED", first_batch.status
            assert_not_equal first_batch.id, next_batch.id
            assert_equal BigDecimal("15.00"), next_batch.reserved_amount.to_d
          end
        end
      end
    end
  end
end
