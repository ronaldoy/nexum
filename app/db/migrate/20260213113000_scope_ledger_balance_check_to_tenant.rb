class ScopeLedgerBalanceCheckToTenant < ActiveRecord::Migration[8.2]
  def up
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
        WHERE txn_id = NEW.txn_id
          AND tenant_id = NEW.tenant_id;

        IF debit_total <> credit_total THEN
          RAISE EXCEPTION 'unbalanced ledger transaction %: debits=% credits=%',
            NEW.txn_id, debit_total, credit_total;
        END IF;

        RETURN NULL;
      END;
      $$;
    SQL
  end

  def down
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
    SQL
  end
end
