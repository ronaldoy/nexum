class RenameLegacyMisspelledFidcIdentifiers < ActiveRecord::Migration[8.2]
  class MigrationUser < ApplicationRecord
    self.table_name = "users"

    encrypts :email_address, deterministic: true
  end

  FIDC_OPERATION_CONSTRAINT_RENAMES = {
    "fdic_operations_pkey" => "fidc_operations_pkey",
    "fdic_operations_provider_check" => "fidc_operations_provider_check",
    "fdic_operations_operation_type_check" => "fidc_operations_operation_type_check",
    "fdic_operations_status_check" => "fidc_operations_status_check",
    "fdic_operations_amount_positive_check" => "fidc_operations_amount_positive_check",
    "fdic_operations_currency_check" => "fidc_operations_currency_check",
    "fdic_operations_idempotency_key_present_check" => "fidc_operations_idempotency_key_present_check",
    "fdic_operations_single_source_reference_check" => "fidc_operations_single_source_reference_check"
  }.freeze

  FIDC_OPERATION_INDEX_RENAMES = {
    "index_fdic_operations_on_tenant_id" => "index_fidc_operations_on_tenant_id",
    "index_fdic_operations_on_anticipation_request_id" => "index_fidc_operations_on_anticipation_request_id",
    "index_fdic_operations_on_receivable_payment_settlement_id" => "index_fidc_operations_on_receivable_payment_settlement_id",
    "index_fdic_operations_on_tenant_idempotency_key" => "index_fidc_operations_on_tenant_idempotency_key",
    "index_fdic_operations_dispatch_scan" => "index_fidc_operations_dispatch_scan",
    "index_fdic_operations_unique_funding_per_request" => "index_fidc_operations_unique_funding_per_request",
    "index_fdic_operations_unique_settlement_per_payment" => "index_fidc_operations_unique_settlement_per_payment"
  }.freeze

  RECEIVABLE_SETTLEMENT_CONSTRAINT_RENAMES = {
    "receivable_payment_settlements_fdic_non_negative_check" => "receivable_payment_settlements_fidc_non_negative_check",
    "receivable_payment_settlements_fdic_before_non_negative_check" => "receivable_payment_settlements_fidc_before_non_negative_check",
    "receivable_payment_settlements_fdic_after_non_negative_check" => "receivable_payment_settlements_fidc_after_non_negative_check",
    "receivable_payment_settlements_fdic_balance_flow_check" => "receivable_payment_settlements_fidc_balance_flow_check"
  }.freeze

  # Leave append-only/audit history untouched. Rewrite only mutable reference data.
  TEXT_COLUMN_REWRITES = {
    fidc_operations: %w[idempotency_key last_error_code last_error_message provider_reference],
    parties: %w[legal_name display_name external_ref],
    roles: %w[name],
    tenants: %w[name]
  }.freeze

  JSON_COLUMN_REWRITES = {
    fidc_operations: %w[metadata],
    parties: %w[metadata],
    tenants: %w[metadata]
  }.freeze
  LEGACY_SEED_EMAIL_RENAMES = {
    "fdic_manager@avertacapital.com.br" => "fidc_manager@avertacapital.com.br",
    "fdic_user@seed.averta.br" => "fidc_user@seed.averta.br"
  }.freeze

  def up
    rename_fidc_operations_table!
    rename_receivable_payment_settlement_columns!
    rewrite_persisted_identifiers!
    rename_seed_user_emails!
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def rename_fidc_operations_table!
    return unless table_exists?(:fdic_operations)
    return if table_exists?(:fidc_operations)

    rename_table :fdic_operations, :fidc_operations

    FIDC_OPERATION_INDEX_RENAMES.each do |old_name, new_name|
      rename_index_if_exists(:fidc_operations, old_name, new_name)
    end

    FIDC_OPERATION_CONSTRAINT_RENAMES.each do |old_name, new_name|
      rename_constraint_if_exists(:fidc_operations, old_name, new_name)
    end

    rename_policy_if_exists(:fidc_operations, "fdic_operations_tenant_policy", "fidc_operations_tenant_policy")
  end

  def rename_receivable_payment_settlement_columns!
    return unless table_exists?(:receivable_payment_settlements)

    rename_column_if_exists(:receivable_payment_settlements, :fdic_amount, :fidc_amount)
    rename_column_if_exists(:receivable_payment_settlements, :fdic_balance_before, :fidc_balance_before)
    rename_column_if_exists(:receivable_payment_settlements, :fdic_balance_after, :fidc_balance_after)

    RECEIVABLE_SETTLEMENT_CONSTRAINT_RENAMES.each do |old_name, new_name|
      rename_constraint_if_exists(:receivable_payment_settlements, old_name, new_name)
    end
  end

  def rewrite_persisted_identifiers!
    TEXT_COLUMN_REWRITES.each do |table_name, columns|
      next unless table_exists?(table_name)

      columns.each do |column_name|
        rewrite_text_column!(table_name, column_name)
      end
    end

    JSON_COLUMN_REWRITES.each do |table_name, columns|
      next unless table_exists?(table_name)

      columns.each do |column_name|
        rewrite_json_column!(table_name, column_name)
      end
    end
  end

  def rename_seed_user_emails!
    return unless table_exists?(:users)
    return unless MigrationUser.table_exists?

    MigrationUser.reset_column_information

    LEGACY_SEED_EMAIL_RENAMES.each do |old_email, new_email|
      user = MigrationUser.find_by(email_address: old_email)
      next unless user

      user.update!(email_address: new_email)
    end
  end

  def rewrite_text_column!(table_name, column_name)
    return unless column_exists?(table_name, column_name)

    quoted_table = quote_table_name(table_name)
    quoted_column = quote_column_name(column_name)

    execute <<~SQL
      UPDATE #{quoted_table}
      SET #{quoted_column} = #{rewritten_text_sql(quoted_column)}
      WHERE #{quoted_column} IS NOT NULL
        AND (#{legacy_match_sql(quoted_column)});
    SQL
  end

  def rewrite_json_column!(table_name, column_name)
    return unless table_exists?(table_name)
    return unless column_exists?(table_name, column_name)

    quoted_table = quote_table_name(table_name)
    quoted_column = quote_column_name(column_name)
    source_sql = "#{quoted_column}::text"

    execute <<~SQL
      UPDATE #{quoted_table}
      SET #{quoted_column} = #{rewritten_text_sql(source_sql)}::jsonb
      WHERE #{quoted_column} IS NOT NULL
        AND (#{legacy_match_sql(source_sql)});
    SQL
  end

  def rename_column_if_exists(table_name, old_name, new_name)
    return unless column_exists?(table_name, old_name)
    return if column_exists?(table_name, new_name)

    rename_column table_name, old_name, new_name
  end

  def rename_index_if_exists(table_name, old_name, new_name)
    return unless index_name_exists?(table_name, old_name)
    return if index_name_exists?(table_name, new_name)

    rename_index table_name, old_name, new_name
  end

  def rename_constraint_if_exists(table_name, old_name, new_name)
    return unless constraint_exists?(table_name, old_name)
    return if constraint_exists?(table_name, new_name)

    execute <<~SQL
      ALTER TABLE #{quote_table_name(table_name)}
      RENAME CONSTRAINT #{quote_column_name(old_name)}
      TO #{quote_column_name(new_name)};
    SQL
  end

  def rename_policy_if_exists(table_name, old_name, new_name)
    return unless policy_exists?(table_name, old_name)
    return if policy_exists?(table_name, new_name)

    execute <<~SQL
      ALTER POLICY #{quote_column_name(old_name)}
      ON #{quote_table_name(table_name)}
      RENAME TO #{quote_column_name(new_name)};
    SQL
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

  def policy_exists?(table_name, policy_name)
    select_value(<<~SQL).present?
      SELECT 1
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = #{quote(table_name.to_s)}
        AND policyname = #{quote(policy_name)}
      LIMIT 1
    SQL
  end

  def rewritten_text_sql(source_sql)
    <<~SQL.squish
      replace(
        replace(
          replace(#{source_sql}, 'Fdic', 'Fidc'),
          'FDIC',
          'FIDC'
        ),
        'fdic',
        'fidc'
      )
    SQL
  end

  def legacy_match_sql(source_sql)
    <<~SQL.squish
      #{source_sql} LIKE '%Fdic%'
      OR #{source_sql} LIKE '%FDIC%'
      OR #{source_sql} LIKE '%fdic%'
    SQL
  end
end
