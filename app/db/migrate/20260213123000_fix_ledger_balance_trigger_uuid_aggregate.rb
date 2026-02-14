class FixLedgerBalanceTriggerUuidAggregate < ActiveRecord::Migration[8.2]
  def up
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
        entry_source_id_text text;
        entry_payment_reference text;
        header_source_type text;
        header_source_id_text text;
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
            MIN(le.source_id::text),
            MIN(le.payment_reference),
            lt.source_type,
            lt.source_id::text,
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
            entry_source_id_text,
            entry_payment_reference,
            header_source_type,
            header_source_id_text,
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

          IF entry_source_type IS DISTINCT FROM header_source_type OR entry_source_id_text IS DISTINCT FROM header_source_id_text THEN
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
  end

  def down
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
        entry_source_id_text text;
        entry_payment_reference text;
        header_source_type text;
        header_source_id_text text;
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
            MIN(le.source_id::text),
            MIN(le.payment_reference),
            lt.source_type,
            lt.source_id::text,
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
            entry_source_id_text,
            entry_payment_reference,
            header_source_type,
            header_source_id_text,
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

          IF entry_source_type IS DISTINCT FROM header_source_type OR entry_source_id_text IS DISTINCT FROM header_source_id_text THEN
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
  end
end
