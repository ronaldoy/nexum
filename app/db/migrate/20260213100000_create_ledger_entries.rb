class CreateLedgerEntries < ActiveRecord::Migration[8.2]
  ENTRY_SIDES = %w[DEBIT CREDIT].freeze

  def change
    create_table :ledger_entries, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.uuid :txn_id, null: false
      t.references :receivable, type: :uuid, foreign_key: true
      t.string :account_code, null: false
      t.string :entry_side, null: false
      t.decimal :amount, precision: 18, scale: 2, null: false
      t.string :currency, null: false, default: "BRL", limit: 3
      t.references :party, type: :uuid, foreign_key: true
      t.string :source_type, null: false
      t.uuid :source_id, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :posted_at, null: false
      t.timestamps
    end

    add_check_constraint :ledger_entries,
      "amount > 0",
      name: "ledger_entries_amount_positive_check"
    add_check_constraint :ledger_entries,
      "entry_side IN ('#{ENTRY_SIDES.join("','")}')",
      name: "ledger_entries_entry_side_check"
    add_check_constraint :ledger_entries,
      "currency = 'BRL'",
      name: "ledger_entries_currency_brl_check"

    add_index :ledger_entries,
      %i[tenant_id txn_id],
      name: "idx_ledger_entries_tenant_txn"
    add_index :ledger_entries,
      %i[tenant_id account_code posted_at],
      name: "idx_ledger_entries_tenant_account_posted"
    add_index :ledger_entries,
      %i[tenant_id receivable_id posted_at],
      name: "idx_ledger_entries_tenant_receivable_posted",
      where: "receivable_id IS NOT NULL"
    add_index :ledger_entries,
      %i[tenant_id source_type source_id],
      name: "idx_ledger_entries_tenant_source"

    create_append_only_triggers("ledger_entries")
    enable_tenant_rls("ledger_entries")
    create_balance_check_trigger
  end

  private

  def create_append_only_triggers(table_name)
    execute <<~SQL
      DROP TRIGGER IF EXISTS #{table_name}_no_update_delete ON #{table_name};
      CREATE TRIGGER #{table_name}_no_update_delete
      BEFORE UPDATE OR DELETE ON #{table_name}
      FOR EACH ROW
      EXECUTE FUNCTION app_forbid_mutation();
    SQL
  end

  def enable_tenant_rls(table_name)
    execute <<~SQL
      ALTER TABLE #{table_name} ENABLE ROW LEVEL SECURITY;
      ALTER TABLE #{table_name} FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS #{table_name}_tenant_policy ON #{table_name};
      CREATE POLICY #{table_name}_tenant_policy
      ON #{table_name}
      USING (tenant_id = app_current_tenant_id())
      WITH CHECK (tenant_id = app_current_tenant_id());
    SQL
  end

  def create_balance_check_trigger
    execute <<~SQL
      CREATE OR REPLACE FUNCTION ledger_entries_check_balance()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        debit_total  numeric(18,2);
        credit_total numeric(18,2);
      BEGIN
        SELECT
          COALESCE(SUM(CASE WHEN entry_side = 'DEBIT'  THEN amount ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN entry_side = 'CREDIT' THEN amount ELSE 0 END), 0)
        INTO debit_total, credit_total
        FROM ledger_entries
        WHERE txn_id = NEW.txn_id;

        IF debit_total <> credit_total THEN
          RAISE EXCEPTION 'unbalanced ledger transaction %: debits=% credits=%',
            NEW.txn_id, debit_total, credit_total;
        END IF;

        RETURN NULL;
      END;
      $$;

      DROP TRIGGER IF EXISTS ledger_entries_balance_check ON ledger_entries;
      CREATE CONSTRAINT TRIGGER ledger_entries_balance_check
      AFTER INSERT ON ledger_entries
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW
      EXECUTE FUNCTION ledger_entries_check_balance();
    SQL
  end
end
