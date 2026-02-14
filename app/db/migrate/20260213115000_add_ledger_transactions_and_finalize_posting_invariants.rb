class AddLedgerTransactionsAndFinalizePostingInvariants < ActiveRecord::Migration[8.2]
  def up
    create_table :ledger_transactions, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.uuid :txn_id, null: false
      t.references :receivable, type: :uuid, foreign_key: true
      t.string :source_type, null: false
      t.uuid :source_id, null: false
      t.string :payment_reference
      t.string :payload_hash
      t.integer :entry_count, null: false
      t.datetime :posted_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint :ledger_transactions,
      "entry_count > 0",
      name: "ledger_transactions_entry_count_positive_check"
    add_check_constraint :ledger_transactions,
      "(source_type <> 'ReceivablePaymentSettlement') OR (payment_reference IS NOT NULL AND btrim(payment_reference) <> '')",
      name: "ledger_transactions_settlement_payment_reference_required_check"

    add_index :ledger_transactions,
      %i[tenant_id txn_id],
      unique: true,
      name: "idx_ledger_transactions_tenant_txn"
    add_index :ledger_transactions,
      %i[tenant_id source_type source_id],
      name: "idx_ledger_transactions_tenant_source"
    add_index :ledger_transactions,
      %i[tenant_id source_type source_id],
      unique: true,
      where: "source_type = 'ReceivablePaymentSettlement'",
      name: "idx_ledger_transactions_settlement_source_unique"
    add_index :ledger_transactions,
      %i[tenant_id payment_reference],
      where: "payment_reference IS NOT NULL",
      name: "idx_ledger_transactions_tenant_payment_reference"

    backfill_ledger_transactions!

    create_append_only_triggers("ledger_transactions")
    enable_tenant_rls("ledger_transactions")

    add_check_constraint :ledger_entries,
      "(source_type <> 'ReceivablePaymentSettlement') OR (payment_reference IS NOT NULL AND btrim(payment_reference) <> '')",
      name: "ledger_entries_settlement_payment_reference_required_check"

    execute <<~SQL
      ALTER TABLE ledger_entries
      ADD CONSTRAINT fk_ledger_entries_ledger_transactions
      FOREIGN KEY (tenant_id, txn_id)
      REFERENCES ledger_transactions (tenant_id, txn_id);
    SQL

    execute <<~SQL
      DROP TRIGGER IF EXISTS ledger_entries_identity_guard ON ledger_entries;
      DROP FUNCTION IF EXISTS ledger_entries_validate_entry_identity();
    SQL

    replace_balance_trigger_with_statement_check!
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS ledger_entries_balance_check ON ledger_entries;
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

    execute <<~SQL
      DROP TRIGGER IF EXISTS ledger_entries_balance_check ON ledger_entries;
      CREATE CONSTRAINT TRIGGER ledger_entries_balance_check
      AFTER INSERT ON ledger_entries
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW
      EXECUTE FUNCTION ledger_entries_check_balance();
    SQL

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
      ALTER TABLE ledger_entries
      DROP CONSTRAINT IF EXISTS fk_ledger_entries_ledger_transactions;
    SQL

    remove_check_constraint :ledger_entries, name: "ledger_entries_settlement_payment_reference_required_check"

    drop_table :ledger_transactions
  end

  private

  def backfill_ledger_transactions!
    execute <<~SQL
      WITH grouped AS (
        SELECT
          tenant_id,
          txn_id,
          COUNT(*) AS entry_count,
          MAX(NULLIF(metadata->>'_txn_payload_hash', '')) AS payload_hash,
          MIN(posted_at) AS posted_at,
          MIN(created_at) AS created_at,
          MAX(updated_at) AS updated_at
        FROM ledger_entries
        GROUP BY tenant_id, txn_id
      ),
      first_entries AS (
        SELECT DISTINCT ON (tenant_id, txn_id)
          tenant_id,
          txn_id,
          source_type,
          source_id,
          receivable_id,
          payment_reference
        FROM ledger_entries
        ORDER BY tenant_id, txn_id, entry_position, created_at, id
      )
      INSERT INTO ledger_transactions (
        id,
        tenant_id,
        txn_id,
        source_type,
        source_id,
        receivable_id,
        payment_reference,
        payload_hash,
        entry_count,
        posted_at,
        metadata,
        created_at,
        updated_at
      )
      SELECT
        gen_random_uuid(),
        grouped.tenant_id,
        grouped.txn_id,
        first_entries.source_type,
        first_entries.source_id,
        first_entries.receivable_id,
        first_entries.payment_reference,
        grouped.payload_hash,
        grouped.entry_count,
        grouped.posted_at,
        '{}'::jsonb,
        grouped.created_at,
        grouped.updated_at
      FROM grouped
      INNER JOIN first_entries
        ON first_entries.tenant_id = grouped.tenant_id
       AND first_entries.txn_id = grouped.txn_id;
    SQL
  end

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

  def replace_balance_trigger_with_statement_check!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION ledger_entries_check_balance()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      DECLARE
        txn_record record;
        debit_total numeric(18,2);
        credit_total numeric(18,2);
        row_count integer;
        min_entry_count integer;
        max_entry_count integer;
        distinct_source_type_count integer;
        distinct_source_id_count integer;
        distinct_payment_reference_count integer;
        entry_source_type text;
        entry_source_id uuid;
        entry_payment_reference text;
        header_source_type text;
        header_source_id uuid;
        header_payment_reference text;
        header_entry_count integer;
      BEGIN
        FOR txn_record IN
          SELECT DISTINCT tenant_id, txn_id
          FROM new_rows
        LOOP
          SELECT
            COALESCE(SUM(CASE WHEN le.entry_side = 'DEBIT'  THEN le.amount ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN le.entry_side = 'CREDIT' THEN le.amount ELSE 0 END), 0),
            COUNT(*),
            MIN(le.txn_entry_count),
            MAX(le.txn_entry_count),
            COUNT(DISTINCT le.source_type),
            COUNT(DISTINCT le.source_id),
            COUNT(DISTINCT COALESCE(le.payment_reference, '')),
            MIN(le.source_type),
            MIN(le.source_id),
            MIN(le.payment_reference),
            lt.source_type,
            lt.source_id,
            lt.payment_reference,
            lt.entry_count
          INTO
            debit_total,
            credit_total,
            row_count,
            min_entry_count,
            max_entry_count,
            distinct_source_type_count,
            distinct_source_id_count,
            distinct_payment_reference_count,
            entry_source_type,
            entry_source_id,
            entry_payment_reference,
            header_source_type,
            header_source_id,
            header_payment_reference,
            header_entry_count
          FROM ledger_entries le
          INNER JOIN ledger_transactions lt
            ON lt.tenant_id = le.tenant_id
           AND lt.txn_id = le.txn_id
          WHERE le.tenant_id = txn_record.tenant_id
            AND le.txn_id = txn_record.txn_id
          GROUP BY lt.source_type, lt.source_id, lt.payment_reference, lt.entry_count;

          IF row_count <> header_entry_count THEN
            RAISE EXCEPTION 'incomplete ledger transaction %: entries=% expected=%',
              txn_record.txn_id, row_count, header_entry_count;
          END IF;

          IF min_entry_count IS DISTINCT FROM max_entry_count OR max_entry_count IS DISTINCT FROM header_entry_count THEN
            RAISE EXCEPTION 'inconsistent txn_entry_count for ledger transaction %', txn_record.txn_id;
          END IF;

          IF distinct_source_type_count <> 1 OR distinct_source_id_count <> 1 THEN
            RAISE EXCEPTION 'inconsistent source linkage for ledger transaction %', txn_record.txn_id;
          END IF;

          IF distinct_payment_reference_count <> 1 THEN
            RAISE EXCEPTION 'inconsistent payment_reference for ledger transaction %', txn_record.txn_id;
          END IF;

          IF entry_source_type IS DISTINCT FROM header_source_type OR entry_source_id IS DISTINCT FROM header_source_id THEN
            RAISE EXCEPTION 'ledger transaction source mismatch %', txn_record.txn_id;
          END IF;

          IF COALESCE(entry_payment_reference, '') <> COALESCE(header_payment_reference, '') THEN
            RAISE EXCEPTION 'ledger transaction payment_reference mismatch %', txn_record.txn_id;
          END IF;

          IF header_source_type = 'ReceivablePaymentSettlement' AND (header_payment_reference IS NULL OR btrim(header_payment_reference) = '') THEN
            RAISE EXCEPTION 'payment_reference is required for settlement ledger transaction %', txn_record.txn_id;
          END IF;

          IF debit_total <> credit_total THEN
            RAISE EXCEPTION 'unbalanced ledger transaction %: debits=% credits=%',
              txn_record.txn_id, debit_total, credit_total;
          END IF;
        END LOOP;

        RETURN NULL;
      END;
      $$;
    SQL

    execute <<~SQL
      DROP TRIGGER IF EXISTS ledger_entries_balance_check ON ledger_entries;
      CREATE TRIGGER ledger_entries_balance_check
      AFTER INSERT ON ledger_entries
      REFERENCING NEW TABLE AS new_rows
      FOR EACH STATEMENT
      EXECUTE FUNCTION ledger_entries_check_balance();
    SQL
  end
end
