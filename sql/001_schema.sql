BEGIN;

CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS ledger;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS integration;

CREATE OR REPLACE FUNCTION app.current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION app.current_actor_id()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('app.actor_id', true), '')
$$;

CREATE OR REPLACE FUNCTION app.current_role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('app.role', true), '')
$$;

CREATE OR REPLACE FUNCTION app.forbid_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'append-only table: % operation not allowed on %', TG_OP, TG_TABLE_NAME;
END;
$$;

CREATE TABLE IF NOT EXISTS core.receivables (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  owner_type text NOT NULL CHECK (owner_type IN ('MEDICO_CPF', 'MEDICO_CNPJ', 'FORNECEDOR_CNPJ')),
  owner_id uuid NOT NULL,
  face_value numeric(18,2) NOT NULL CHECK (face_value > 0),
  currency char(3) NOT NULL DEFAULT 'BRL',
  due_at timestamptz NOT NULL,
  status text NOT NULL CHECK (status IN ('PERFORMED', 'ANTICIPATION_REQUESTED', 'SETTLED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.anticipation_requests (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  receivable_id uuid NOT NULL REFERENCES core.receivables(id),
  actor_id text NOT NULL,
  requested_amount numeric(18,2) NOT NULL CHECK (requested_amount > 0),
  discount_rate numeric(12,8) NOT NULL CHECK (discount_rate >= 0),
  discount_amount numeric(18,2) NOT NULL CHECK (discount_amount >= 0),
  net_amount numeric(18,2) NOT NULL CHECK (net_amount > 0),
  days_to_maturity integer NOT NULL CHECK (days_to_maturity >= 0),
  idempotency_key text NOT NULL,
  status text NOT NULL CHECK (status IN ('REQUESTED', 'FUNDED', 'SETTLED', 'CANCELLED')),
  document_id uuid NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_anticipation_idempotency
  ON core.anticipation_requests (tenant_id, idempotency_key);

CREATE TABLE IF NOT EXISTS core.receivables_snapshot (
  receivable_id uuid PRIMARY KEY REFERENCES core.receivables(id),
  tenant_id uuid NOT NULL,
  status text NOT NULL,
  last_event_type text NOT NULL,
  last_event_at timestamptz NOT NULL,
  last_anticipation_id uuid NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.documents (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  receivable_id uuid NOT NULL REFERENCES core.receivables(id),
  document_type text NOT NULL,
  storage_key text NOT NULL,
  sha256 text NOT NULL,
  signer_id text NOT NULL,
  signer_role text NOT NULL,
  provider_envelope_id text NULL,
  signed_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit.receivable_events (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  receivable_id uuid NOT NULL REFERENCES core.receivables(id),
  seq bigint NOT NULL,
  event_type text NOT NULL,
  occurred_at timestamptz NOT NULL,
  actor_id text NOT NULL,
  actor_role text NOT NULL,
  payload jsonb NOT NULL,
  prev_hash text NULL,
  event_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_receivable_events_seq
  ON audit.receivable_events (receivable_id, seq);

CREATE UNIQUE INDEX IF NOT EXISTS uq_receivable_events_hash
  ON audit.receivable_events (event_hash);

CREATE TABLE IF NOT EXISTS audit.document_events (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  document_id uuid NOT NULL REFERENCES core.documents(id),
  receivable_id uuid NOT NULL REFERENCES core.receivables(id),
  event_type text NOT NULL,
  occurred_at timestamptz NOT NULL,
  actor_id text NOT NULL,
  actor_role text NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ledger.entries (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  txn_id uuid NOT NULL,
  receivable_id uuid NOT NULL REFERENCES core.receivables(id),
  account_code text NOT NULL,
  entry_side text NOT NULL CHECK (entry_side IN ('DEBIT', 'CREDIT')),
  amount numeric(18,2) NOT NULL CHECK (amount > 0),
  currency char(3) NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_ledger_txn
  ON ledger.entries (tenant_id, txn_id);

CREATE TABLE IF NOT EXISTS integration.outbox_events (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL,
  aggregate_type text NOT NULL,
  aggregate_id uuid NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  status text NOT NULL CHECK (status IN ('PENDING', 'SENT', 'FAILED')),
  attempts integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz NULL
);

CREATE INDEX IF NOT EXISTS ix_outbox_pending
  ON integration.outbox_events (tenant_id, status, created_at);

DROP TRIGGER IF EXISTS trg_no_mutation_receivable_events ON audit.receivable_events;
CREATE TRIGGER trg_no_mutation_receivable_events
BEFORE UPDATE OR DELETE ON audit.receivable_events
FOR EACH ROW EXECUTE FUNCTION app.forbid_mutation();

DROP TRIGGER IF EXISTS trg_no_mutation_document_events ON audit.document_events;
CREATE TRIGGER trg_no_mutation_document_events
BEFORE UPDATE OR DELETE ON audit.document_events
FOR EACH ROW EXECUTE FUNCTION app.forbid_mutation();

DROP TRIGGER IF EXISTS trg_no_mutation_ledger_entries ON ledger.entries;
CREATE TRIGGER trg_no_mutation_ledger_entries
BEFORE UPDATE OR DELETE ON ledger.entries
FOR EACH ROW EXECUTE FUNCTION app.forbid_mutation();

ALTER TABLE core.receivables ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.receivables FORCE ROW LEVEL SECURITY;
ALTER TABLE core.anticipation_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.anticipation_requests FORCE ROW LEVEL SECURITY;
ALTER TABLE core.receivables_snapshot ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.receivables_snapshot FORCE ROW LEVEL SECURITY;
ALTER TABLE core.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.documents FORCE ROW LEVEL SECURITY;
ALTER TABLE audit.receivable_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.receivable_events FORCE ROW LEVEL SECURITY;
ALTER TABLE audit.document_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.document_events FORCE ROW LEVEL SECURITY;
ALTER TABLE ledger.entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.entries FORCE ROW LEVEL SECURITY;
ALTER TABLE integration.outbox_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE integration.outbox_events FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_tenant_core_receivables ON core.receivables;
CREATE POLICY p_tenant_core_receivables
ON core.receivables
USING (tenant_id = app.current_tenant_id())
WITH CHECK (tenant_id = app.current_tenant_id());

DROP POLICY IF EXISTS p_tenant_core_anticipation_requests ON core.anticipation_requests;
CREATE POLICY p_tenant_core_anticipation_requests
ON core.anticipation_requests
USING (tenant_id = app.current_tenant_id())
WITH CHECK (tenant_id = app.current_tenant_id());

DROP POLICY IF EXISTS p_tenant_core_receivables_snapshot ON core.receivables_snapshot;
CREATE POLICY p_tenant_core_receivables_snapshot
ON core.receivables_snapshot
USING (tenant_id = app.current_tenant_id())
WITH CHECK (tenant_id = app.current_tenant_id());

DROP POLICY IF EXISTS p_tenant_core_documents ON core.documents;
CREATE POLICY p_tenant_core_documents
ON core.documents
USING (tenant_id = app.current_tenant_id())
WITH CHECK (tenant_id = app.current_tenant_id());

DROP POLICY IF EXISTS p_tenant_audit_receivable_events ON audit.receivable_events;
CREATE POLICY p_tenant_audit_receivable_events
ON audit.receivable_events
USING (tenant_id = app.current_tenant_id())
WITH CHECK (tenant_id = app.current_tenant_id());

DROP POLICY IF EXISTS p_tenant_audit_document_events ON audit.document_events;
CREATE POLICY p_tenant_audit_document_events
ON audit.document_events
USING (tenant_id = app.current_tenant_id())
WITH CHECK (tenant_id = app.current_tenant_id());

DROP POLICY IF EXISTS p_tenant_ledger_entries ON ledger.entries;
CREATE POLICY p_tenant_ledger_entries
ON ledger.entries
USING (tenant_id = app.current_tenant_id())
WITH CHECK (tenant_id = app.current_tenant_id());

DROP POLICY IF EXISTS p_tenant_integration_outbox_events ON integration.outbox_events;
CREATE POLICY p_tenant_integration_outbox_events
ON integration.outbox_events
USING (tenant_id = app.current_tenant_id())
WITH CHECK (tenant_id = app.current_tenant_id());

COMMIT;
