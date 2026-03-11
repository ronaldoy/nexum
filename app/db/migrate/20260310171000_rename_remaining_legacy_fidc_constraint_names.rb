class RenameRemainingLegacyFidcConstraintNames < ActiveRecord::Migration[8.2]
  FIDC_OPERATION_NOT_NULL_CONSTRAINT_RENAMES = {
    "fdic_operations_id_not_null" => "fidc_operations_id_not_null",
    "fdic_operations_tenant_id_not_null" => "fidc_operations_tenant_id_not_null",
    "fdic_operations_provider_not_null" => "fidc_operations_provider_not_null",
    "fdic_operations_operation_type_not_null" => "fidc_operations_operation_type_not_null",
    "fdic_operations_status_not_null" => "fidc_operations_status_not_null",
    "fdic_operations_amount_not_null" => "fidc_operations_amount_not_null",
    "fdic_operations_currency_not_null" => "fidc_operations_currency_not_null",
    "fdic_operations_idempotency_key_not_null" => "fidc_operations_idempotency_key_not_null",
    "fdic_operations_requested_at_not_null" => "fidc_operations_requested_at_not_null",
    "fdic_operations_metadata_not_null" => "fidc_operations_metadata_not_null",
    "fdic_operations_created_at_not_null" => "fidc_operations_created_at_not_null",
    "fdic_operations_updated_at_not_null" => "fidc_operations_updated_at_not_null"
  }.freeze

  RECEIVABLE_SETTLEMENT_NOT_NULL_CONSTRAINT_RENAMES = {
    "receivable_payment_settlements_fdic_amount_not_null" => "receivable_payment_settlements_fidc_amount_not_null",
    "receivable_payment_settlements_fdic_balance_before_not_null" => "receivable_payment_settlements_fidc_balance_before_not_null",
    "receivable_payment_settlements_fdic_balance_after_not_null" => "receivable_payment_settlements_fidc_balance_after_not_null"
  }.freeze

  def up
    rename_constraints(:fidc_operations, FIDC_OPERATION_NOT_NULL_CONSTRAINT_RENAMES)
    rename_constraints(:receivable_payment_settlements, RECEIVABLE_SETTLEMENT_NOT_NULL_CONSTRAINT_RENAMES)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def rename_constraints(table_name, renames)
    return unless table_exists?(table_name)

    renames.each do |old_name, new_name|
      next unless constraint_exists?(table_name, old_name)
      next if constraint_exists?(table_name, new_name)

      execute <<~SQL
        ALTER TABLE #{quote_table_name(table_name)}
        RENAME CONSTRAINT #{quote_column_name(old_name)}
        TO #{quote_column_name(new_name)};
      SQL
    end
  end

  def constraint_exists?(table_name, constraint_name)
    select_value(<<~SQL).present?
      SELECT 1
      FROM pg_constraint
      WHERE conname = #{quote(constraint_name)}
        AND conrelid = to_regclass(#{quote("public.#{table_name}")})
      LIMIT 1
    SQL
  end
end
