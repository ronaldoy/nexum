class HardenLedgerEntryIdentityAndReconciliation < ActiveRecord::Migration[8.2]
  def up
    add_column :ledger_entries, :entry_position, :integer
    add_column :ledger_entries, :txn_entry_count, :integer
    add_column :ledger_entries, :payment_reference, :string

    execute <<~SQL
      WITH ranked AS (
        SELECT
          id,
          ROW_NUMBER() OVER (PARTITION BY tenant_id, txn_id ORDER BY created_at, id) AS position,
          COUNT(*) OVER (PARTITION BY tenant_id, txn_id) AS total
        FROM ledger_entries
      )
      UPDATE ledger_entries AS le
      SET
        entry_position = ranked.position,
        txn_entry_count = ranked.total
      FROM ranked
      WHERE le.id = ranked.id;
    SQL

    change_column_null :ledger_entries, :entry_position, false
    change_column_null :ledger_entries, :txn_entry_count, false

    add_check_constraint :ledger_entries,
      "entry_position > 0",
      name: "ledger_entries_entry_position_positive_check"
    add_check_constraint :ledger_entries,
      "txn_entry_count > 0",
      name: "ledger_entries_txn_entry_count_positive_check"
    add_check_constraint :ledger_entries,
      "entry_position <= txn_entry_count",
      name: "ledger_entries_entry_position_lte_count_check"

    add_index :ledger_entries,
      %i[tenant_id txn_id entry_position],
      unique: true,
      name: "idx_ledger_entries_tenant_txn_entry_position"
    add_index :ledger_entries,
      %i[tenant_id payment_reference],
      where: "payment_reference IS NOT NULL",
      name: "idx_ledger_entries_tenant_payment_reference"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION ledger_entries_validate_entry_identity()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        existing_count integer;
        existing_expected integer;
      BEGIN
        SELECT COUNT(*), MAX(txn_entry_count)
        INTO existing_count, existing_expected
        FROM ledger_entries
        WHERE tenant_id = NEW.tenant_id
          AND txn_id = NEW.txn_id;

        IF existing_count > 0 THEN
          IF existing_expected <> NEW.txn_entry_count THEN
            RAISE EXCEPTION 'inconsistent txn_entry_count for ledger transaction %', NEW.txn_id;
          END IF;

          IF existing_count >= existing_expected THEN
            RAISE EXCEPTION 'ledger transaction % is already finalized', NEW.txn_id;
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute <<~SQL
      DROP TRIGGER IF EXISTS ledger_entries_identity_guard ON ledger_entries;
      CREATE TRIGGER ledger_entries_identity_guard
      BEFORE INSERT ON ledger_entries
      FOR EACH ROW
      EXECUTE FUNCTION ledger_entries_validate_entry_identity();
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION ledger_entries_check_balance()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        debit_total numeric(18,2);
        credit_total numeric(18,2);
        entry_count integer;
        min_expected integer;
        max_expected integer;
      BEGIN
        SELECT
          COALESCE(SUM(CASE WHEN entry_side = 'DEBIT'  THEN amount ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN entry_side = 'CREDIT' THEN amount ELSE 0 END), 0),
          COUNT(*),
          MIN(txn_entry_count),
          MAX(txn_entry_count)
        INTO debit_total, credit_total, entry_count, min_expected, max_expected
        FROM ledger_entries
        WHERE txn_id = NEW.txn_id
          AND tenant_id = NEW.tenant_id;

        IF min_expected IS DISTINCT FROM max_expected THEN
          RAISE EXCEPTION 'inconsistent txn_entry_count for ledger transaction %', NEW.txn_id;
        END IF;

        IF entry_count <> max_expected THEN
          RAISE EXCEPTION 'incomplete ledger transaction %: entries=% expected=%',
            NEW.txn_id, entry_count, max_expected;
        END IF;

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

    execute <<~SQL
      DROP TRIGGER IF EXISTS ledger_entries_identity_guard ON ledger_entries;
      DROP FUNCTION IF EXISTS ledger_entries_validate_entry_identity();
    SQL

    remove_index :ledger_entries, name: "idx_ledger_entries_tenant_payment_reference"
    remove_index :ledger_entries, name: "idx_ledger_entries_tenant_txn_entry_position"
    remove_check_constraint :ledger_entries, name: "ledger_entries_entry_position_lte_count_check"
    remove_check_constraint :ledger_entries, name: "ledger_entries_txn_entry_count_positive_check"
    remove_check_constraint :ledger_entries, name: "ledger_entries_entry_position_positive_check"
    remove_column :ledger_entries, :payment_reference
    remove_column :ledger_entries, :txn_entry_count
    remove_column :ledger_entries, :entry_position
  end
end
