SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: app_active_storage_blob_metadata_json(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_active_storage_blob_metadata_json(blob_metadata text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
  IF blob_metadata IS NULL OR btrim(blob_metadata) = '' THEN
    RETURN '{}'::jsonb;
  END IF;

  BEGIN
    RETURN blob_metadata::jsonb;
  EXCEPTION
    WHEN invalid_text_representation THEN
      RETURN '{}'::jsonb;
  END;
END;
$$;


--
-- Name: app_active_storage_blob_tenant_id(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_active_storage_blob_tenant_id(blob_metadata text) RETURNS uuid
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  tenant_raw text;
BEGIN
  tenant_raw := NULLIF(app_active_storage_blob_metadata_json(blob_metadata)->>'tenant_id', '');
  IF tenant_raw IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    RETURN tenant_raw::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      RETURN NULL;
  END;
END;
$$;


--
-- Name: app_current_tenant_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_current_tenant_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;


--
-- Name: app_forbid_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_forbid_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'append-only table: % operation not allowed on %', TG_OP, TG_TABLE_NAME;
END;
$$;


--
-- Name: app_protect_anticipation_requests(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_protect_anticipation_requests() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'DELETE not allowed on anticipation_requests';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF current_setting('app.allow_anticipation_status_transition', true) <> 'true' THEN
      RAISE EXCEPTION 'UPDATE not allowed on anticipation_requests without status transition gate';
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
      OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
      OR NEW.receivable_id IS DISTINCT FROM OLD.receivable_id
      OR NEW.receivable_allocation_id IS DISTINCT FROM OLD.receivable_allocation_id
      OR NEW.requester_party_id IS DISTINCT FROM OLD.requester_party_id
      OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
      OR NEW.requested_amount IS DISTINCT FROM OLD.requested_amount
      OR NEW.discount_rate IS DISTINCT FROM OLD.discount_rate
      OR NEW.discount_amount IS DISTINCT FROM OLD.discount_amount
      OR NEW.net_amount IS DISTINCT FROM OLD.net_amount
      OR NEW.channel IS DISTINCT FROM OLD.channel
      OR NEW.requested_at IS DISTINCT FROM OLD.requested_at
      OR NEW.settlement_target_date IS DISTINCT FROM OLD.settlement_target_date
      OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'Only status, funded_at, settled_at, metadata, and updated_at can change on anticipation_requests';
    END IF;

    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'Status must change when updating anticipation_requests';
    END IF;

    IF NOT (
      (OLD.status = 'REQUESTED' AND NEW.status IN ('APPROVED', 'CANCELLED', 'REJECTED')) OR
      (OLD.status = 'APPROVED' AND NEW.status IN ('FUNDED', 'SETTLED', 'CANCELLED')) OR
      (OLD.status = 'FUNDED' AND NEW.status IN ('SETTLED', 'CANCELLED'))
    ) THEN
      RAISE EXCEPTION 'Invalid anticipation_requests status transition from % to %', OLD.status, NEW.status;
    END IF;

    IF NEW.status = 'FUNDED' AND NEW.funded_at IS NULL THEN
      RAISE EXCEPTION 'funded_at is required when status transitions to FUNDED';
    END IF;

    IF NEW.status = 'SETTLED' AND NEW.settled_at IS NULL THEN
      RAISE EXCEPTION 'settled_at is required when status transitions to SETTLED';
    END IF;

    IF NEW.status <> 'FUNDED' AND NEW.funded_at IS DISTINCT FROM OLD.funded_at THEN
      RAISE EXCEPTION 'funded_at can only change when status transitions to FUNDED';
    END IF;

    IF NEW.status <> 'SETTLED' AND NEW.settled_at IS DISTINCT FROM OLD.settled_at THEN
      RAISE EXCEPTION 'settled_at can only change when status transitions to SETTLED';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: app_resolve_tenant_id_by_slug(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_resolve_tenant_id_by_slug(slug text) RETURNS uuid
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  SELECT id
  FROM tenants
  WHERE tenants.slug = app_resolve_tenant_id_by_slug.slug
    AND active = true
  LIMIT 1;
$$;


--
-- Name: ledger_entries_check_balance(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ledger_entries_check_balance() RETURNS trigger
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: action_ip_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.action_ip_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    actor_party_id uuid,
    action_type character varying NOT NULL,
    ip_address inet NOT NULL,
    user_agent character varying,
    request_id character varying,
    endpoint_path character varying,
    http_method character varying,
    channel character varying NOT NULL,
    target_type character varying,
    target_id uuid,
    success boolean DEFAULT true NOT NULL,
    occurred_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT action_ip_logs_channel_check CHECK (((channel)::text = ANY (ARRAY[('API'::character varying)::text, ('PORTAL'::character varying)::text, ('WORKER'::character varying)::text, ('WEBHOOK'::character varying)::text, ('ADMIN'::character varying)::text])))
);

ALTER TABLE ONLY public.action_ip_logs FORCE ROW LEVEL SECURITY;


--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id bigint NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id text NOT NULL,
    blob_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.active_storage_attachments FORCE ROW LEVEL SECURITY;


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_attachments_id_seq OWNED BY public.active_storage_attachments.id;


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id bigint NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    service_name character varying NOT NULL,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.active_storage_blobs FORCE ROW LEVEL SECURITY;


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_blobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_blobs_id_seq OWNED BY public.active_storage_blobs.id;


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id bigint NOT NULL,
    blob_id bigint NOT NULL,
    variation_digest character varying NOT NULL
);

ALTER TABLE ONLY public.active_storage_variant_records FORCE ROW LEVEL SECURITY;


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_variant_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_variant_records_id_seq OWNED BY public.active_storage_variant_records.id;


--
-- Name: anticipation_request_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anticipation_request_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    anticipation_request_id uuid NOT NULL,
    sequence integer NOT NULL,
    event_type character varying NOT NULL,
    status_before character varying,
    status_after character varying,
    actor_party_id uuid,
    actor_role character varying,
    request_id character varying,
    occurred_at timestamp(6) without time zone NOT NULL,
    prev_hash character varying,
    event_hash character varying NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.anticipation_request_events FORCE ROW LEVEL SECURITY;


--
-- Name: anticipation_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anticipation_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    receivable_id uuid NOT NULL,
    receivable_allocation_id uuid,
    requester_party_id uuid NOT NULL,
    idempotency_key character varying NOT NULL,
    requested_amount numeric(18,2) NOT NULL,
    discount_rate numeric(12,8) NOT NULL,
    discount_amount numeric(18,2) NOT NULL,
    net_amount numeric(18,2) NOT NULL,
    status character varying DEFAULT 'REQUESTED'::character varying NOT NULL,
    channel character varying DEFAULT 'API'::character varying NOT NULL,
    requested_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    funded_at timestamp(6) without time zone,
    settled_at timestamp(6) without time zone,
    settlement_target_date date,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT anticipation_requests_channel_check CHECK (((channel)::text = ANY (ARRAY[('API'::character varying)::text, ('PORTAL'::character varying)::text, ('WEBHOOK'::character varying)::text, ('INTERNAL'::character varying)::text]))),
    CONSTRAINT anticipation_requests_discount_amount_check CHECK ((discount_amount >= (0)::numeric)),
    CONSTRAINT anticipation_requests_discount_rate_check CHECK ((discount_rate >= (0)::numeric)),
    CONSTRAINT anticipation_requests_net_amount_positive_check CHECK ((net_amount > (0)::numeric)),
    CONSTRAINT anticipation_requests_requested_amount_positive_check CHECK ((requested_amount > (0)::numeric)),
    CONSTRAINT anticipation_requests_status_check CHECK (((status)::text = ANY (ARRAY[('REQUESTED'::character varying)::text, ('APPROVED'::character varying)::text, ('FUNDED'::character varying)::text, ('SETTLED'::character varying)::text, ('CANCELLED'::character varying)::text, ('REJECTED'::character varying)::text])))
);

ALTER TABLE ONLY public.anticipation_requests FORCE ROW LEVEL SECURITY;


--
-- Name: anticipation_settlement_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anticipation_settlement_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    receivable_payment_settlement_id uuid CONSTRAINT anticipation_settlement_ent_receivable_payment_settlem_not_null NOT NULL,
    anticipation_request_id uuid CONSTRAINT anticipation_settlement_entrie_anticipation_request_id_not_null NOT NULL,
    settled_amount numeric(18,2) NOT NULL,
    settled_at timestamp(6) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT anticipation_settlement_entries_settled_positive_check CHECK ((settled_amount > (0)::numeric))
);

ALTER TABLE ONLY public.anticipation_settlement_entries FORCE ROW LEVEL SECURITY;


--
-- Name: api_access_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_access_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id bigint,
    name character varying NOT NULL,
    token_identifier character varying NOT NULL,
    token_digest character varying NOT NULL,
    scopes character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    expires_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    last_used_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT api_access_tokens_token_digest_check CHECK ((char_length((token_digest)::text) > 0)),
    CONSTRAINT api_access_tokens_token_identifier_check CHECK ((char_length((token_identifier)::text) > 0))
);

ALTER TABLE ONLY public.api_access_tokens FORCE ROW LEVEL SECURITY;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: assignment_contracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assignment_contracts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    receivable_id uuid NOT NULL,
    anticipation_request_id uuid,
    assignor_party_id uuid NOT NULL,
    assignee_party_id uuid NOT NULL,
    contract_number character varying NOT NULL,
    status character varying DEFAULT 'DRAFT'::character varying NOT NULL,
    currency character varying(3) DEFAULT 'BRL'::character varying NOT NULL,
    assigned_amount numeric(18,2) NOT NULL,
    idempotency_key character varying NOT NULL,
    signed_at timestamp(6) without time zone,
    effective_at timestamp(6) without time zone,
    cancelled_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT assignment_contracts_assigned_amount_positive_check CHECK ((assigned_amount > (0)::numeric)),
    CONSTRAINT assignment_contracts_cancelled_at_required_check CHECK ((((status)::text <> 'CANCELLED'::text) OR (cancelled_at IS NOT NULL))),
    CONSTRAINT assignment_contracts_cancelled_at_state_check CHECK (((cancelled_at IS NULL) OR ((status)::text = 'CANCELLED'::text))),
    CONSTRAINT assignment_contracts_currency_brl_check CHECK (((currency)::text = 'BRL'::text)),
    CONSTRAINT assignment_contracts_idempotency_key_present_check CHECK ((btrim((idempotency_key)::text) <> ''::text)),
    CONSTRAINT assignment_contracts_signed_at_required_check CHECK ((((status)::text = ANY (ARRAY[('DRAFT'::character varying)::text, ('CANCELLED'::character varying)::text])) OR (signed_at IS NOT NULL))),
    CONSTRAINT assignment_contracts_status_check CHECK (((status)::text = ANY (ARRAY[('DRAFT'::character varying)::text, ('SIGNED'::character varying)::text, ('ACTIVE'::character varying)::text, ('SETTLED'::character varying)::text, ('CANCELLED'::character varying)::text])))
);

ALTER TABLE ONLY public.assignment_contracts FORCE ROW LEVEL SECURITY;


--
-- Name: auth_challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_challenges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    actor_party_id uuid NOT NULL,
    purpose character varying NOT NULL,
    delivery_channel character varying NOT NULL,
    destination_masked character varying NOT NULL,
    code_digest character varying NOT NULL,
    status character varying DEFAULT 'PENDING'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 5 NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    consumed_at timestamp(6) without time zone,
    request_id character varying,
    target_type character varying NOT NULL,
    target_id uuid NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT auth_challenges_attempts_check CHECK ((attempts >= 0)),
    CONSTRAINT auth_challenges_delivery_channel_check CHECK (((delivery_channel)::text = ANY (ARRAY[('EMAIL'::character varying)::text, ('WHATSAPP'::character varying)::text]))),
    CONSTRAINT auth_challenges_max_attempts_check CHECK ((max_attempts > 0)),
    CONSTRAINT auth_challenges_status_check CHECK (((status)::text = ANY (ARRAY[('PENDING'::character varying)::text, ('VERIFIED'::character varying)::text, ('EXPIRED'::character varying)::text, ('CANCELLED'::character varying)::text])))
);

ALTER TABLE ONLY public.auth_challenges FORCE ROW LEVEL SECURITY;


--
-- Name: document_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    document_id uuid NOT NULL,
    receivable_id uuid NOT NULL,
    actor_party_id uuid,
    event_type character varying NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    request_id character varying,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.document_events FORCE ROW LEVEL SECURITY;


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    receivable_id uuid NOT NULL,
    actor_party_id uuid NOT NULL,
    document_type character varying NOT NULL,
    signature_method character varying DEFAULT 'OWN_PLATFORM_CONFIRMATION'::character varying NOT NULL,
    status character varying DEFAULT 'SIGNED'::character varying NOT NULL,
    sha256 character varying NOT NULL,
    storage_key character varying NOT NULL,
    signed_at timestamp(6) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT documents_status_check CHECK (((status)::text = ANY (ARRAY[('SIGNED'::character varying)::text, ('REVOKED'::character varying)::text, ('SUPERSEDED'::character varying)::text])))
);

ALTER TABLE ONLY public.documents FORCE ROW LEVEL SECURITY;


--
-- Name: escrow_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.escrow_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    party_id uuid NOT NULL,
    provider character varying NOT NULL,
    account_type character varying DEFAULT 'ESCROW'::character varying NOT NULL,
    status character varying DEFAULT 'PENDING'::character varying NOT NULL,
    provider_account_id character varying,
    provider_request_id character varying,
    last_synced_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT escrow_accounts_account_type_check CHECK (((account_type)::text = 'ESCROW'::text)),
    CONSTRAINT escrow_accounts_provider_check CHECK (((provider)::text = ANY ((ARRAY['QITECH'::character varying, 'STARKBANK'::character varying])::text[]))),
    CONSTRAINT escrow_accounts_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'ACTIVE'::character varying, 'REJECTED'::character varying, 'FAILED'::character varying, 'CLOSED'::character varying])::text[])))
);

ALTER TABLE ONLY public.escrow_accounts FORCE ROW LEVEL SECURITY;


--
-- Name: escrow_payouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.escrow_payouts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    anticipation_request_id uuid,
    party_id uuid NOT NULL,
    escrow_account_id uuid NOT NULL,
    provider character varying NOT NULL,
    status character varying DEFAULT 'PENDING'::character varying NOT NULL,
    amount numeric(18,2) NOT NULL,
    currency character varying(3) DEFAULT 'BRL'::character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    provider_transfer_id character varying,
    requested_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    processed_at timestamp(6) without time zone,
    last_error_code character varying,
    last_error_message character varying,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    receivable_payment_settlement_id uuid,
    CONSTRAINT escrow_payouts_amount_positive_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT escrow_payouts_currency_brl_check CHECK (((currency)::text = 'BRL'::text)),
    CONSTRAINT escrow_payouts_idempotency_key_present_check CHECK ((btrim((idempotency_key)::text) <> ''::text)),
    CONSTRAINT escrow_payouts_provider_check CHECK (((provider)::text = ANY ((ARRAY['QITECH'::character varying, 'STARKBANK'::character varying])::text[]))),
    CONSTRAINT escrow_payouts_source_reference_check CHECK (((anticipation_request_id IS NOT NULL) OR (receivable_payment_settlement_id IS NOT NULL))),
    CONSTRAINT escrow_payouts_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'SENT'::character varying, 'FAILED'::character varying])::text[])))
);

ALTER TABLE ONLY public.escrow_payouts FORCE ROW LEVEL SECURITY;


--
-- Name: hospital_ownerships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hospital_ownerships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    organization_party_id uuid NOT NULL,
    hospital_party_id uuid NOT NULL,
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT hospital_ownerships_distinct_parties_check CHECK ((organization_party_id <> hospital_party_id))
);

ALTER TABLE ONLY public.hospital_ownerships FORCE ROW LEVEL SECURITY;


--
-- Name: kyc_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.kyc_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    kyc_profile_id uuid NOT NULL,
    party_id uuid NOT NULL,
    document_type character varying NOT NULL,
    document_number text,
    issuing_country character varying DEFAULT 'BR'::character varying NOT NULL,
    issuing_state character varying(2),
    issued_on date,
    expires_on date,
    is_key_document boolean DEFAULT false NOT NULL,
    status character varying DEFAULT 'SUBMITTED'::character varying NOT NULL,
    verified_at timestamp(6) without time zone,
    rejection_reason character varying,
    storage_key character varying NOT NULL,
    sha256 character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT kyc_documents_document_type_check CHECK (((document_type)::text = ANY (ARRAY[('CPF'::character varying)::text, ('CNPJ'::character varying)::text, ('RG'::character varying)::text, ('CNH'::character varying)::text, ('PASSPORT'::character varying)::text, ('PROOF_OF_ADDRESS'::character varying)::text, ('SELFIE'::character varying)::text, ('CONTRACT'::character varying)::text, ('OTHER'::character varying)::text]))),
    CONSTRAINT kyc_documents_issuing_state_check CHECK (((issuing_state IS NULL) OR ((issuing_state)::text = ANY (ARRAY[('AC'::character varying)::text, ('AL'::character varying)::text, ('AP'::character varying)::text, ('AM'::character varying)::text, ('BA'::character varying)::text, ('CE'::character varying)::text, ('DF'::character varying)::text, ('ES'::character varying)::text, ('GO'::character varying)::text, ('MA'::character varying)::text, ('MT'::character varying)::text, ('MS'::character varying)::text, ('MG'::character varying)::text, ('PA'::character varying)::text, ('PB'::character varying)::text, ('PR'::character varying)::text, ('PE'::character varying)::text, ('PI'::character varying)::text, ('RJ'::character varying)::text, ('RN'::character varying)::text, ('RS'::character varying)::text, ('RO'::character varying)::text, ('RR'::character varying)::text, ('SC'::character varying)::text, ('SP'::character varying)::text, ('SE'::character varying)::text, ('TO'::character varying)::text])))),
    CONSTRAINT kyc_documents_key_document_type_check CHECK (((NOT is_key_document) OR ((document_type)::text = ANY (ARRAY[('CPF'::character varying)::text, ('CNPJ'::character varying)::text])))),
    CONSTRAINT kyc_documents_non_key_identity_docs_check CHECK ((((document_type)::text <> ALL (ARRAY[('RG'::character varying)::text, ('CNH'::character varying)::text, ('PASSPORT'::character varying)::text])) OR (is_key_document = false))),
    CONSTRAINT kyc_documents_sha256_present_check CHECK ((char_length((sha256)::text) > 0)),
    CONSTRAINT kyc_documents_status_check CHECK (((status)::text = ANY (ARRAY[('SUBMITTED'::character varying)::text, ('VERIFIED'::character varying)::text, ('REJECTED'::character varying)::text, ('EXPIRED'::character varying)::text]))),
    CONSTRAINT kyc_documents_storage_key_present_check CHECK ((char_length((storage_key)::text) > 0))
);

ALTER TABLE ONLY public.kyc_documents FORCE ROW LEVEL SECURITY;


--
-- Name: kyc_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.kyc_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    kyc_profile_id uuid NOT NULL,
    party_id uuid NOT NULL,
    actor_party_id uuid,
    event_type character varying NOT NULL,
    occurred_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    request_id character varying,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.kyc_events FORCE ROW LEVEL SECURITY;


--
-- Name: kyc_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.kyc_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    party_id uuid NOT NULL,
    status character varying DEFAULT 'DRAFT'::character varying NOT NULL,
    risk_level character varying DEFAULT 'UNKNOWN'::character varying NOT NULL,
    submitted_at timestamp(6) without time zone,
    reviewed_at timestamp(6) without time zone,
    reviewer_party_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT kyc_profiles_risk_level_check CHECK (((risk_level)::text = ANY (ARRAY[('UNKNOWN'::character varying)::text, ('LOW'::character varying)::text, ('MEDIUM'::character varying)::text, ('HIGH'::character varying)::text]))),
    CONSTRAINT kyc_profiles_status_check CHECK (((status)::text = ANY (ARRAY[('DRAFT'::character varying)::text, ('PENDING_REVIEW'::character varying)::text, ('NEEDS_INFORMATION'::character varying)::text, ('APPROVED'::character varying)::text, ('REJECTED'::character varying)::text])))
);

ALTER TABLE ONLY public.kyc_profiles FORCE ROW LEVEL SECURITY;


--
-- Name: ledger_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    txn_id uuid NOT NULL,
    receivable_id uuid,
    account_code character varying NOT NULL,
    entry_side character varying NOT NULL,
    amount numeric(18,2) NOT NULL,
    currency character varying(3) DEFAULT 'BRL'::character varying NOT NULL,
    party_id uuid,
    source_type character varying NOT NULL,
    source_id uuid NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    posted_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    entry_position integer NOT NULL,
    txn_entry_count integer NOT NULL,
    payment_reference character varying,
    CONSTRAINT ledger_entries_amount_positive_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT ledger_entries_currency_brl_check CHECK (((currency)::text = 'BRL'::text)),
    CONSTRAINT ledger_entries_entry_position_lte_count_check CHECK ((entry_position <= txn_entry_count)),
    CONSTRAINT ledger_entries_entry_position_positive_check CHECK ((entry_position > 0)),
    CONSTRAINT ledger_entries_entry_side_check CHECK (((entry_side)::text = ANY (ARRAY[('DEBIT'::character varying)::text, ('CREDIT'::character varying)::text]))),
    CONSTRAINT ledger_entries_settlement_payment_reference_required_check CHECK ((((source_type)::text <> 'ReceivablePaymentSettlement'::text) OR ((payment_reference IS NOT NULL) AND (btrim((payment_reference)::text) <> ''::text)))),
    CONSTRAINT ledger_entries_txn_entry_count_positive_check CHECK ((txn_entry_count > 0))
);

ALTER TABLE ONLY public.ledger_entries FORCE ROW LEVEL SECURITY;


--
-- Name: ledger_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    txn_id uuid NOT NULL,
    receivable_id uuid,
    source_type character varying NOT NULL,
    source_id uuid NOT NULL,
    payment_reference character varying,
    payload_hash character varying NOT NULL,
    entry_count integer NOT NULL,
    posted_at timestamp(6) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    actor_party_id uuid,
    actor_role character varying,
    request_id character varying,
    CONSTRAINT ledger_transactions_entry_count_positive_check CHECK ((entry_count > 0)),
    CONSTRAINT ledger_transactions_payload_hash_present_check CHECK ((btrim((payload_hash)::text) <> ''::text)),
    CONSTRAINT ledger_transactions_settlement_payment_reference_required_check CHECK ((((source_type)::text <> 'ReceivablePaymentSettlement'::text) OR ((payment_reference IS NOT NULL) AND (btrim((payment_reference)::text) <> ''::text))))
);

ALTER TABLE ONLY public.ledger_transactions FORCE ROW LEVEL SECURITY;


--
-- Name: outbox_dispatch_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbox_dispatch_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    outbox_event_id uuid NOT NULL,
    attempt_number integer NOT NULL,
    status character varying NOT NULL,
    occurred_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    next_attempt_at timestamp(6) without time zone,
    error_code character varying,
    error_message character varying,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT outbox_dispatch_attempts_attempt_number_check CHECK ((attempt_number > 0)),
    CONSTRAINT outbox_dispatch_attempts_status_check CHECK (((status)::text = ANY ((ARRAY['SENT'::character varying, 'RETRY_SCHEDULED'::character varying, 'DEAD_LETTER'::character varying])::text[])))
);

ALTER TABLE ONLY public.outbox_dispatch_attempts FORCE ROW LEVEL SECURITY;


--
-- Name: outbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbox_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    aggregate_type character varying NOT NULL,
    aggregate_id uuid NOT NULL,
    event_type character varying NOT NULL,
    status character varying DEFAULT 'PENDING'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp(6) without time zone,
    sent_at timestamp(6) without time zone,
    idempotency_key character varying,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT outbox_events_status_check CHECK (((status)::text = ANY (ARRAY[('PENDING'::character varying)::text, ('SENT'::character varying)::text, ('FAILED'::character varying)::text, ('CANCELLED'::character varying)::text])))
);

ALTER TABLE ONLY public.outbox_events FORCE ROW LEVEL SECURITY;


--
-- Name: parties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parties (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    kind character varying NOT NULL,
    external_ref character varying,
    document_number text,
    legal_name text NOT NULL,
    display_name text,
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    document_type character varying NOT NULL,
    CONSTRAINT parties_document_type_check CHECK (((document_type)::text = ANY (ARRAY[('CPF'::character varying)::text, ('CNPJ'::character varying)::text]))),
    CONSTRAINT parties_document_type_kind_check CHECK (((((kind)::text = 'PHYSICIAN_PF'::text) AND ((document_type)::text = 'CPF'::text)) OR (((kind)::text <> 'PHYSICIAN_PF'::text) AND ((document_type)::text = 'CNPJ'::text)))),
    CONSTRAINT parties_kind_check CHECK (((kind)::text = ANY (ARRAY[('HOSPITAL'::character varying)::text, ('SUPPLIER'::character varying)::text, ('PHYSICIAN_PF'::character varying)::text, ('LEGAL_ENTITY_PJ'::character varying)::text, ('FIDC'::character varying)::text, ('PLATFORM'::character varying)::text])))
);

ALTER TABLE ONLY public.parties FORCE ROW LEVEL SECURITY;


--
-- Name: physician_anticipation_authorizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.physician_anticipation_authorizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    legal_entity_party_id uuid CONSTRAINT physician_anticipation_authoriza_legal_entity_party_id_not_null NOT NULL,
    granted_by_membership_id uuid CONSTRAINT physician_anticipation_author_granted_by_membership_id_not_null NOT NULL,
    beneficiary_physician_party_id uuid CONSTRAINT physician_anticipation_auth_beneficiary_physician_part_not_null NOT NULL,
    status character varying DEFAULT 'ACTIVE'::character varying NOT NULL,
    valid_from timestamp(6) without time zone NOT NULL,
    valid_until timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT physician_authorization_status_check CHECK (((status)::text = ANY (ARRAY[('ACTIVE'::character varying)::text, ('REVOKED'::character varying)::text, ('EXPIRED'::character varying)::text])))
);

ALTER TABLE ONLY public.physician_anticipation_authorizations FORCE ROW LEVEL SECURITY;


--
-- Name: physician_cnpj_split_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.physician_cnpj_split_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    legal_entity_party_id uuid NOT NULL,
    scope character varying DEFAULT 'SHARED_CNPJ'::character varying NOT NULL,
    cnpj_share_rate numeric(12,8) DEFAULT 0.3 NOT NULL,
    physician_share_rate numeric(12,8) DEFAULT 0.7 NOT NULL,
    status character varying DEFAULT 'ACTIVE'::character varying NOT NULL,
    effective_from timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    effective_until timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT physician_cnpj_split_policies_cnpj_rate_check CHECK (((cnpj_share_rate >= (0)::numeric) AND (cnpj_share_rate <= (1)::numeric))),
    CONSTRAINT physician_cnpj_split_policies_physician_rate_check CHECK (((physician_share_rate >= (0)::numeric) AND (physician_share_rate <= (1)::numeric))),
    CONSTRAINT physician_cnpj_split_policies_scope_check CHECK (((scope)::text = 'SHARED_CNPJ'::text)),
    CONSTRAINT physician_cnpj_split_policies_status_check CHECK (((status)::text = ANY (ARRAY[('ACTIVE'::character varying)::text, ('INACTIVE'::character varying)::text]))),
    CONSTRAINT physician_cnpj_split_policies_total_rate_check CHECK (((cnpj_share_rate + physician_share_rate) = 1.00000000))
);

ALTER TABLE ONLY public.physician_cnpj_split_policies FORCE ROW LEVEL SECURITY;


--
-- Name: physician_legal_entity_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.physician_legal_entity_memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    physician_party_id uuid NOT NULL,
    legal_entity_party_id uuid CONSTRAINT physician_legal_entity_membershi_legal_entity_party_id_not_null NOT NULL,
    membership_role character varying NOT NULL,
    status character varying DEFAULT 'ACTIVE'::character varying NOT NULL,
    joined_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    left_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT physician_membership_role_check CHECK (((membership_role)::text = ANY (ARRAY[('ADMIN'::character varying)::text, ('MEMBER'::character varying)::text]))),
    CONSTRAINT physician_membership_status_check CHECK (((status)::text = ANY (ARRAY[('ACTIVE'::character varying)::text, ('INACTIVE'::character varying)::text])))
);

ALTER TABLE ONLY public.physician_legal_entity_memberships FORCE ROW LEVEL SECURITY;


--
-- Name: physicians; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.physicians (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    party_id uuid NOT NULL,
    full_name text NOT NULL,
    email text,
    phone text,
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    crm_number character varying,
    crm_state character varying(2),
    CONSTRAINT physicians_crm_number_length_check CHECK (((crm_number IS NULL) OR ((char_length((crm_number)::text) >= 4) AND (char_length((crm_number)::text) <= 10)))),
    CONSTRAINT physicians_crm_pair_presence_check CHECK ((((crm_number IS NULL) AND (crm_state IS NULL)) OR ((crm_number IS NOT NULL) AND (crm_state IS NOT NULL)))),
    CONSTRAINT physicians_crm_state_check CHECK (((crm_state IS NULL) OR ((crm_state)::text = ANY (ARRAY[('AC'::character varying)::text, ('AL'::character varying)::text, ('AP'::character varying)::text, ('AM'::character varying)::text, ('BA'::character varying)::text, ('CE'::character varying)::text, ('DF'::character varying)::text, ('ES'::character varying)::text, ('GO'::character varying)::text, ('MA'::character varying)::text, ('MT'::character varying)::text, ('MS'::character varying)::text, ('MG'::character varying)::text, ('PA'::character varying)::text, ('PB'::character varying)::text, ('PR'::character varying)::text, ('PE'::character varying)::text, ('PI'::character varying)::text, ('RJ'::character varying)::text, ('RN'::character varying)::text, ('RS'::character varying)::text, ('RO'::character varying)::text, ('RR'::character varying)::text, ('SC'::character varying)::text, ('SP'::character varying)::text, ('SE'::character varying)::text, ('TO'::character varying)::text]))))
);

ALTER TABLE ONLY public.physicians FORCE ROW LEVEL SECURITY;


--
-- Name: provider_webhook_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_webhook_receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    provider character varying NOT NULL,
    provider_event_id character varying NOT NULL,
    event_type character varying,
    signature character varying,
    payload_sha256 character varying NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_headers jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying NOT NULL,
    error_code character varying,
    error_message character varying,
    processed_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT provider_webhook_receipts_event_id_present_check CHECK ((btrim((provider_event_id)::text) <> ''::text)),
    CONSTRAINT provider_webhook_receipts_payload_sha256_check CHECK (((payload_sha256)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT provider_webhook_receipts_provider_check CHECK (((provider)::text = ANY ((ARRAY['QITECH'::character varying, 'STARKBANK'::character varying])::text[]))),
    CONSTRAINT provider_webhook_receipts_status_check CHECK (((status)::text = ANY ((ARRAY['PROCESSED'::character varying, 'IGNORED'::character varying, 'FAILED'::character varying])::text[])))
);

ALTER TABLE ONLY public.provider_webhook_receipts FORCE ROW LEVEL SECURITY;


--
-- Name: receivable_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receivable_allocations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    receivable_id uuid NOT NULL,
    sequence integer NOT NULL,
    allocated_party_id uuid NOT NULL,
    physician_party_id uuid,
    gross_amount numeric(18,2) NOT NULL,
    tax_reserve_amount numeric(18,2) DEFAULT 0.0 NOT NULL,
    eligible_for_anticipation boolean DEFAULT true NOT NULL,
    status character varying DEFAULT 'OPEN'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT receivable_allocations_gross_amount_check CHECK ((gross_amount >= (0)::numeric)),
    CONSTRAINT receivable_allocations_status_check CHECK (((status)::text = ANY (ARRAY[('OPEN'::character varying)::text, ('SETTLED'::character varying)::text, ('CANCELLED'::character varying)::text]))),
    CONSTRAINT receivable_allocations_tax_reserve_amount_check CHECK ((tax_reserve_amount >= (0)::numeric))
);

ALTER TABLE ONLY public.receivable_allocations FORCE ROW LEVEL SECURITY;


--
-- Name: receivable_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receivable_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    receivable_id uuid NOT NULL,
    sequence bigint NOT NULL,
    event_type character varying NOT NULL,
    actor_party_id uuid,
    actor_role character varying,
    occurred_at timestamp(6) without time zone NOT NULL,
    request_id character varying,
    prev_hash character varying,
    event_hash character varying NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.receivable_events FORCE ROW LEVEL SECURITY;


--
-- Name: receivable_kinds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receivable_kinds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid,
    code character varying NOT NULL,
    name character varying NOT NULL,
    source_family character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT receivable_kinds_source_family_check CHECK (((source_family)::text = ANY (ARRAY[('PHYSICIAN'::character varying)::text, ('SUPPLIER'::character varying)::text, ('OTHER'::character varying)::text])))
);

ALTER TABLE ONLY public.receivable_kinds FORCE ROW LEVEL SECURITY;


--
-- Name: receivable_payment_settlements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receivable_payment_settlements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    receivable_id uuid NOT NULL,
    receivable_allocation_id uuid,
    paid_amount numeric(18,2) NOT NULL,
    cnpj_amount numeric(18,2) DEFAULT 0.0 NOT NULL,
    fdic_amount numeric(18,2) DEFAULT 0.0 NOT NULL,
    beneficiary_amount numeric(18,2) DEFAULT 0.0 NOT NULL,
    fdic_balance_before numeric(18,2) DEFAULT 0.0 NOT NULL,
    fdic_balance_after numeric(18,2) DEFAULT 0.0 NOT NULL,
    paid_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    payment_reference character varying NOT NULL,
    request_id character varying,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    idempotency_key character varying NOT NULL,
    CONSTRAINT receivable_payment_settlements_beneficiary_non_negative_check CHECK ((beneficiary_amount >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_cnpj_non_negative_check CHECK ((cnpj_amount >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_fdic_after_non_negative_check CHECK ((fdic_balance_after >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_fdic_balance_flow_check CHECK ((fdic_balance_before >= fdic_balance_after)),
    CONSTRAINT receivable_payment_settlements_fdic_before_non_negative_check CHECK ((fdic_balance_before >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_fdic_non_negative_check CHECK ((fdic_amount >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_idempotency_key_present_check CHECK ((btrim((idempotency_key)::text) <> ''::text)),
    CONSTRAINT receivable_payment_settlements_paid_positive_check CHECK ((paid_amount > (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_payment_reference_present_check CHECK ((btrim((payment_reference)::text) <> ''::text)),
    CONSTRAINT receivable_payment_settlements_split_total_check CHECK ((((cnpj_amount + fdic_amount) + beneficiary_amount) = paid_amount))
);

ALTER TABLE ONLY public.receivable_payment_settlements FORCE ROW LEVEL SECURITY;


--
-- Name: receivable_statistics_daily; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receivable_statistics_daily (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    stat_date date NOT NULL,
    receivable_kind_id uuid NOT NULL,
    metric_scope character varying NOT NULL,
    scope_party_id uuid,
    receivable_count bigint DEFAULT 0 NOT NULL,
    gross_amount numeric(18,2) DEFAULT 0.0 NOT NULL,
    anticipated_count bigint DEFAULT 0 NOT NULL,
    anticipated_amount numeric(18,2) DEFAULT 0.0 NOT NULL,
    settled_count bigint DEFAULT 0 NOT NULL,
    settled_amount numeric(18,2) DEFAULT 0.0 NOT NULL,
    last_computed_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT receivable_statistics_daily_metric_scope_check CHECK (((metric_scope)::text = ANY (ARRAY[('GLOBAL'::character varying)::text, ('DEBTOR'::character varying)::text, ('CREDITOR'::character varying)::text, ('BENEFICIARY'::character varying)::text])))
);

ALTER TABLE ONLY public.receivable_statistics_daily FORCE ROW LEVEL SECURITY;


--
-- Name: receivables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receivables (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    receivable_kind_id uuid NOT NULL,
    debtor_party_id uuid NOT NULL,
    creditor_party_id uuid NOT NULL,
    beneficiary_party_id uuid NOT NULL,
    contract_reference character varying,
    external_reference character varying,
    gross_amount numeric(18,2) NOT NULL,
    currency character varying(3) DEFAULT 'BRL'::character varying NOT NULL,
    performed_at timestamp(6) without time zone NOT NULL,
    due_at timestamp(6) without time zone NOT NULL,
    cutoff_at timestamp(6) without time zone NOT NULL,
    status character varying DEFAULT 'PERFORMED'::character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT receivables_currency_brl_check CHECK (((currency)::text = 'BRL'::text)),
    CONSTRAINT receivables_gross_amount_positive_check CHECK ((gross_amount > (0)::numeric)),
    CONSTRAINT receivables_status_check CHECK (((status)::text = ANY (ARRAY[('PERFORMED'::character varying)::text, ('ANTICIPATION_REQUESTED'::character varying)::text, ('FUNDED'::character varying)::text, ('SETTLED'::character varying)::text, ('CANCELLED'::character varying)::text])))
);

ALTER TABLE ONLY public.receivables FORCE ROW LEVEL SECURITY;


--
-- Name: reconciliation_exceptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reconciliation_exceptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    resolved_by_party_id uuid,
    source character varying NOT NULL,
    provider character varying NOT NULL,
    external_event_id character varying NOT NULL,
    code character varying NOT NULL,
    message character varying NOT NULL,
    payload_sha256 character varying,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'OPEN'::character varying NOT NULL,
    occurrences_count integer DEFAULT 1 NOT NULL,
    first_seen_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_seen_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    resolved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT reconciliation_exceptions_code_present_check CHECK ((btrim((code)::text) <> ''::text)),
    CONSTRAINT reconciliation_exceptions_external_event_id_present_check CHECK ((btrim((external_event_id)::text) <> ''::text)),
    CONSTRAINT reconciliation_exceptions_message_present_check CHECK ((btrim((message)::text) <> ''::text)),
    CONSTRAINT reconciliation_exceptions_occurrences_count_positive_check CHECK ((occurrences_count > 0)),
    CONSTRAINT reconciliation_exceptions_payload_sha256_check CHECK (((payload_sha256 IS NULL) OR ((payload_sha256)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT reconciliation_exceptions_provider_check CHECK (((provider)::text = ANY ((ARRAY['QITECH'::character varying, 'STARKBANK'::character varying])::text[]))),
    CONSTRAINT reconciliation_exceptions_source_check CHECK (((source)::text = 'ESCROW_WEBHOOK'::text)),
    CONSTRAINT reconciliation_exceptions_status_check CHECK (((status)::text = ANY ((ARRAY['OPEN'::character varying, 'RESOLVED'::character varying])::text[])))
);

ALTER TABLE ONLY public.reconciliation_exceptions FORCE ROW LEVEL SECURITY;


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT roles_code_check CHECK (((code)::text = ANY (ARRAY[('hospital_admin'::character varying)::text, ('supplier_user'::character varying)::text, ('ops_admin'::character varying)::text, ('physician_pf_user'::character varying)::text, ('physician_pj_admin'::character varying)::text, ('physician_pj_member'::character varying)::text, ('integration_api'::character varying)::text])))
);

ALTER TABLE ONLY public.roles FORCE ROW LEVEL SECURITY;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    admin_webauthn_verified_at timestamp(6) without time zone
);

ALTER TABLE ONLY public.sessions FORCE ROW LEVEL SECURITY;


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug public.citext NOT NULL,
    name character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.tenants FORCE ROW LEVEL SECURITY;


--
-- Name: user_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id bigint NOT NULL,
    role_id uuid NOT NULL,
    assigned_by_user_id bigint,
    assigned_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.user_roles FORCE ROW LEVEL SECURITY;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email_address text NOT NULL,
    password_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    tenant_id uuid NOT NULL,
    party_id uuid,
    mfa_enabled boolean DEFAULT false NOT NULL,
    mfa_secret character varying,
    mfa_last_otp_at timestamp(6) without time zone,
    webauthn_id character varying
);

ALTER TABLE ONLY public.users FORCE ROW LEVEL SECURITY;


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: webauthn_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webauthn_credentials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id bigint NOT NULL,
    webauthn_id character varying NOT NULL,
    public_key text NOT NULL,
    sign_count bigint DEFAULT 0 NOT NULL,
    nickname character varying,
    last_used_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT webauthn_credentials_sign_count_non_negative_check CHECK ((sign_count >= 0))
);

ALTER TABLE ONLY public.webauthn_credentials FORCE ROW LEVEL SECURITY;


--
-- Name: active_storage_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments ALTER COLUMN id SET DEFAULT nextval('public.active_storage_attachments_id_seq'::regclass);


--
-- Name: active_storage_blobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs ALTER COLUMN id SET DEFAULT nextval('public.active_storage_blobs_id_seq'::regclass);


--
-- Name: active_storage_variant_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records ALTER COLUMN id SET DEFAULT nextval('public.active_storage_variant_records_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: action_ip_logs action_ip_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.action_ip_logs
    ADD CONSTRAINT action_ip_logs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: anticipation_request_events anticipation_request_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_request_events
    ADD CONSTRAINT anticipation_request_events_pkey PRIMARY KEY (id);


--
-- Name: anticipation_requests anticipation_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_requests
    ADD CONSTRAINT anticipation_requests_pkey PRIMARY KEY (id);


--
-- Name: anticipation_settlement_entries anticipation_settlement_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_settlement_entries
    ADD CONSTRAINT anticipation_settlement_entries_pkey PRIMARY KEY (id);


--
-- Name: api_access_tokens api_access_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_access_tokens
    ADD CONSTRAINT api_access_tokens_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: assignment_contracts assignment_contracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assignment_contracts
    ADD CONSTRAINT assignment_contracts_pkey PRIMARY KEY (id);


--
-- Name: auth_challenges auth_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_challenges
    ADD CONSTRAINT auth_challenges_pkey PRIMARY KEY (id);


--
-- Name: document_events document_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_events
    ADD CONSTRAINT document_events_pkey PRIMARY KEY (id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: escrow_accounts escrow_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.escrow_accounts
    ADD CONSTRAINT escrow_accounts_pkey PRIMARY KEY (id);


--
-- Name: escrow_payouts escrow_payouts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.escrow_payouts
    ADD CONSTRAINT escrow_payouts_pkey PRIMARY KEY (id);


--
-- Name: hospital_ownerships hospital_ownerships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hospital_ownerships
    ADD CONSTRAINT hospital_ownerships_pkey PRIMARY KEY (id);


--
-- Name: kyc_documents kyc_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_documents
    ADD CONSTRAINT kyc_documents_pkey PRIMARY KEY (id);


--
-- Name: kyc_events kyc_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_events
    ADD CONSTRAINT kyc_events_pkey PRIMARY KEY (id);


--
-- Name: kyc_profiles kyc_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_profiles
    ADD CONSTRAINT kyc_profiles_pkey PRIMARY KEY (id);


--
-- Name: ledger_entries ledger_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT ledger_entries_pkey PRIMARY KEY (id);


--
-- Name: ledger_transactions ledger_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_transactions
    ADD CONSTRAINT ledger_transactions_pkey PRIMARY KEY (id);


--
-- Name: outbox_dispatch_attempts outbox_dispatch_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_dispatch_attempts
    ADD CONSTRAINT outbox_dispatch_attempts_pkey PRIMARY KEY (id);


--
-- Name: outbox_events outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT outbox_events_pkey PRIMARY KEY (id);


--
-- Name: parties parties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_pkey PRIMARY KEY (id);


--
-- Name: physician_anticipation_authorizations physician_anticipation_authorizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_anticipation_authorizations
    ADD CONSTRAINT physician_anticipation_authorizations_pkey PRIMARY KEY (id);


--
-- Name: physician_cnpj_split_policies physician_cnpj_split_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_cnpj_split_policies
    ADD CONSTRAINT physician_cnpj_split_policies_pkey PRIMARY KEY (id);


--
-- Name: physician_legal_entity_memberships physician_legal_entity_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_legal_entity_memberships
    ADD CONSTRAINT physician_legal_entity_memberships_pkey PRIMARY KEY (id);


--
-- Name: physicians physicians_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physicians
    ADD CONSTRAINT physicians_pkey PRIMARY KEY (id);


--
-- Name: provider_webhook_receipts provider_webhook_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_webhook_receipts
    ADD CONSTRAINT provider_webhook_receipts_pkey PRIMARY KEY (id);


--
-- Name: receivable_allocations receivable_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_allocations
    ADD CONSTRAINT receivable_allocations_pkey PRIMARY KEY (id);


--
-- Name: receivable_events receivable_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_events
    ADD CONSTRAINT receivable_events_pkey PRIMARY KEY (id);


--
-- Name: receivable_kinds receivable_kinds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_kinds
    ADD CONSTRAINT receivable_kinds_pkey PRIMARY KEY (id);


--
-- Name: receivable_payment_settlements receivable_payment_settlements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_payment_settlements
    ADD CONSTRAINT receivable_payment_settlements_pkey PRIMARY KEY (id);


--
-- Name: receivable_statistics_daily receivable_statistics_daily_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_statistics_daily
    ADD CONSTRAINT receivable_statistics_daily_pkey PRIMARY KEY (id);


--
-- Name: receivables receivables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivables
    ADD CONSTRAINT receivables_pkey PRIMARY KEY (id);


--
-- Name: reconciliation_exceptions reconciliation_exceptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_exceptions
    ADD CONSTRAINT reconciliation_exceptions_pkey PRIMARY KEY (id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: webauthn_credentials webauthn_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webauthn_credentials
    ADD CONSTRAINT webauthn_credentials_pkey PRIMARY KEY (id);


--
-- Name: idx_anticipation_request_events_unique_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_anticipation_request_events_unique_seq ON public.anticipation_request_events USING btree (tenant_id, anticipation_request_id, sequence);


--
-- Name: idx_ase_tenant_request_settled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ase_tenant_request_settled_at ON public.anticipation_settlement_entries USING btree (tenant_id, anticipation_request_id, settled_at);


--
-- Name: idx_ase_unique_request_per_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ase_unique_request_per_payment ON public.anticipation_settlement_entries USING btree (receivable_payment_settlement_id, anticipation_request_id);


--
-- Name: idx_kyc_documents_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_kyc_documents_lookup ON public.kyc_documents USING btree (tenant_id, party_id, document_type, status);


--
-- Name: idx_kyc_documents_unique_key_per_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_kyc_documents_unique_key_per_type ON public.kyc_documents USING btree (tenant_id, party_id, document_type) WHERE (is_key_document = true);


--
-- Name: idx_kyc_events_tenant_party_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_kyc_events_tenant_party_time ON public.kyc_events USING btree (tenant_id, party_id, occurred_at);


--
-- Name: idx_kyc_events_tenant_profile_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_kyc_events_tenant_profile_time ON public.kyc_events USING btree (tenant_id, kyc_profile_id, occurred_at);


--
-- Name: idx_ledger_entries_tenant_account_posted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_entries_tenant_account_posted ON public.ledger_entries USING btree (tenant_id, account_code, posted_at);


--
-- Name: idx_ledger_entries_tenant_payment_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_entries_tenant_payment_reference ON public.ledger_entries USING btree (tenant_id, payment_reference) WHERE (payment_reference IS NOT NULL);


--
-- Name: idx_ledger_entries_tenant_receivable_posted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_entries_tenant_receivable_posted ON public.ledger_entries USING btree (tenant_id, receivable_id, posted_at) WHERE (receivable_id IS NOT NULL);


--
-- Name: idx_ledger_entries_tenant_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_entries_tenant_source ON public.ledger_entries USING btree (tenant_id, source_type, source_id);


--
-- Name: idx_ledger_entries_tenant_txn; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_entries_tenant_txn ON public.ledger_entries USING btree (tenant_id, txn_id);


--
-- Name: idx_ledger_entries_tenant_txn_entry_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ledger_entries_tenant_txn_entry_position ON public.ledger_entries USING btree (tenant_id, txn_id, entry_position);


--
-- Name: idx_ledger_transactions_settlement_source_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ledger_transactions_settlement_source_unique ON public.ledger_transactions USING btree (tenant_id, source_type, source_id) WHERE ((source_type)::text = 'ReceivablePaymentSettlement'::text);


--
-- Name: idx_ledger_transactions_tenant_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_transactions_tenant_actor ON public.ledger_transactions USING btree (tenant_id, actor_party_id);


--
-- Name: idx_ledger_transactions_tenant_payment_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_transactions_tenant_payment_reference ON public.ledger_transactions USING btree (tenant_id, payment_reference) WHERE (payment_reference IS NOT NULL);


--
-- Name: idx_ledger_transactions_tenant_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_transactions_tenant_source ON public.ledger_transactions USING btree (tenant_id, source_type, source_id);


--
-- Name: idx_ledger_transactions_tenant_txn; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ledger_transactions_tenant_txn ON public.ledger_transactions USING btree (tenant_id, txn_id);


--
-- Name: idx_on_anticipation_request_id_a246566b52; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_anticipation_request_id_a246566b52 ON public.anticipation_settlement_entries USING btree (anticipation_request_id);


--
-- Name: idx_on_beneficiary_physician_party_id_49cb368edd; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_beneficiary_physician_party_id_49cb368edd ON public.physician_anticipation_authorizations USING btree (beneficiary_physician_party_id);


--
-- Name: idx_on_granted_by_membership_id_ba97263f49; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_granted_by_membership_id_ba97263f49 ON public.physician_anticipation_authorizations USING btree (granted_by_membership_id);


--
-- Name: idx_on_legal_entity_party_id_0544188f89; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_legal_entity_party_id_0544188f89 ON public.physician_legal_entity_memberships USING btree (legal_entity_party_id);


--
-- Name: idx_on_legal_entity_party_id_67e9dbdf42; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_legal_entity_party_id_67e9dbdf42 ON public.physician_anticipation_authorizations USING btree (legal_entity_party_id);


--
-- Name: idx_on_receivable_allocation_id_cc033624f4; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_receivable_allocation_id_cc033624f4 ON public.receivable_payment_settlements USING btree (receivable_allocation_id);


--
-- Name: idx_on_receivable_payment_settlement_id_98a0387829; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_receivable_payment_settlement_id_98a0387829 ON public.anticipation_settlement_entries USING btree (receivable_payment_settlement_id);


--
-- Name: idx_physicians_tenant_crm; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_physicians_tenant_crm ON public.physicians USING btree (tenant_id, crm_state, crm_number) WHERE (crm_number IS NOT NULL);


--
-- Name: idx_rps_tenant_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rps_tenant_idempotency_key ON public.receivable_payment_settlements USING btree (tenant_id, idempotency_key);


--
-- Name: idx_rps_tenant_payment_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rps_tenant_payment_ref ON public.receivable_payment_settlements USING btree (tenant_id, payment_reference);


--
-- Name: idx_rps_tenant_receivable_paid_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rps_tenant_receivable_paid_at ON public.receivable_payment_settlements USING btree (tenant_id, receivable_id, paid_at);


--
-- Name: index_action_ip_logs_on_actor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_action_ip_logs_on_actor_party_id ON public.action_ip_logs USING btree (actor_party_id);


--
-- Name: index_action_ip_logs_on_tenant_actor_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_action_ip_logs_on_tenant_actor_occurred_at ON public.action_ip_logs USING btree (tenant_id, actor_party_id, occurred_at);


--
-- Name: index_action_ip_logs_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_action_ip_logs_on_tenant_id ON public.action_ip_logs USING btree (tenant_id);


--
-- Name: index_action_ip_logs_on_tenant_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_action_ip_logs_on_tenant_occurred_at ON public.action_ip_logs USING btree (tenant_id, occurred_at);


--
-- Name: index_action_ip_logs_on_tenant_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_action_ip_logs_on_tenant_request_id ON public.action_ip_logs USING btree (tenant_id, request_id);


--
-- Name: index_active_physician_authorizations; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_physician_authorizations ON public.physician_anticipation_authorizations USING btree (tenant_id, legal_entity_party_id, beneficiary_physician_party_id) WHERE ((status)::text = 'ACTIVE'::text);


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_blobs_on_tenant_direct_upload_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_tenant_direct_upload_idempotency ON public.active_storage_blobs USING btree (public.app_active_storage_blob_tenant_id(metadata), ((public.app_active_storage_blob_metadata_json(metadata) ->> 'direct_upload_idempotency_key'::text))) WHERE ((public.app_active_storage_blob_tenant_id(metadata) IS NOT NULL) AND (COALESCE((public.app_active_storage_blob_metadata_json(metadata) ->> 'direct_upload_idempotency_key'::text), ''::text) <> ''::text));


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_anticipation_request_events_on_actor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anticipation_request_events_on_actor_party_id ON public.anticipation_request_events USING btree (actor_party_id);


--
-- Name: index_anticipation_request_events_on_anticipation_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anticipation_request_events_on_anticipation_request_id ON public.anticipation_request_events USING btree (anticipation_request_id);


--
-- Name: index_anticipation_request_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anticipation_request_events_on_tenant_id ON public.anticipation_request_events USING btree (tenant_id);


--
-- Name: index_anticipation_requests_on_receivable_allocation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anticipation_requests_on_receivable_allocation_id ON public.anticipation_requests USING btree (receivable_allocation_id);


--
-- Name: index_anticipation_requests_on_receivable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anticipation_requests_on_receivable_id ON public.anticipation_requests USING btree (receivable_id);


--
-- Name: index_anticipation_requests_on_requester_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anticipation_requests_on_requester_party_id ON public.anticipation_requests USING btree (requester_party_id);


--
-- Name: index_anticipation_requests_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anticipation_requests_on_tenant_id ON public.anticipation_requests USING btree (tenant_id);


--
-- Name: index_anticipation_requests_on_tenant_id_and_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_anticipation_requests_on_tenant_id_and_idempotency_key ON public.anticipation_requests USING btree (tenant_id, idempotency_key);


--
-- Name: index_anticipation_requests_on_tenant_receivable_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anticipation_requests_on_tenant_receivable_status ON public.anticipation_requests USING btree (tenant_id, receivable_id, status);


--
-- Name: index_anticipation_settlement_entries_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_anticipation_settlement_entries_on_tenant_id ON public.anticipation_settlement_entries USING btree (tenant_id);


--
-- Name: index_api_access_tokens_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_access_tokens_on_tenant_id ON public.api_access_tokens USING btree (tenant_id);


--
-- Name: index_api_access_tokens_on_tenant_lifecycle; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_access_tokens_on_tenant_lifecycle ON public.api_access_tokens USING btree (tenant_id, revoked_at, expires_at);


--
-- Name: index_api_access_tokens_on_token_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_access_tokens_on_token_identifier ON public.api_access_tokens USING btree (token_identifier);


--
-- Name: index_api_access_tokens_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_access_tokens_on_user_id ON public.api_access_tokens USING btree (user_id);


--
-- Name: index_assignment_contracts_on_anticipation_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_assignment_contracts_on_anticipation_request_id ON public.assignment_contracts USING btree (anticipation_request_id);


--
-- Name: index_assignment_contracts_on_assignee_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_assignment_contracts_on_assignee_party_id ON public.assignment_contracts USING btree (assignee_party_id);


--
-- Name: index_assignment_contracts_on_assignor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_assignment_contracts_on_assignor_party_id ON public.assignment_contracts USING btree (assignor_party_id);


--
-- Name: index_assignment_contracts_on_receivable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_assignment_contracts_on_receivable_id ON public.assignment_contracts USING btree (receivable_id);


--
-- Name: index_assignment_contracts_on_tenant_contract_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_assignment_contracts_on_tenant_contract_number ON public.assignment_contracts USING btree (tenant_id, contract_number);


--
-- Name: index_assignment_contracts_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_assignment_contracts_on_tenant_id ON public.assignment_contracts USING btree (tenant_id);


--
-- Name: index_assignment_contracts_on_tenant_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_assignment_contracts_on_tenant_idempotency_key ON public.assignment_contracts USING btree (tenant_id, idempotency_key);


--
-- Name: index_assignment_contracts_on_tenant_receivable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_assignment_contracts_on_tenant_receivable ON public.assignment_contracts USING btree (tenant_id, receivable_id);


--
-- Name: index_auth_challenges_active_by_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_auth_challenges_active_by_actor ON public.auth_challenges USING btree (tenant_id, actor_party_id, status, expires_at);


--
-- Name: index_auth_challenges_on_actor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_auth_challenges_on_actor_party_id ON public.auth_challenges USING btree (actor_party_id);


--
-- Name: index_auth_challenges_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_auth_challenges_on_tenant_id ON public.auth_challenges USING btree (tenant_id);


--
-- Name: index_document_events_on_actor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_events_on_actor_party_id ON public.document_events USING btree (actor_party_id);


--
-- Name: index_document_events_on_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_events_on_document_id ON public.document_events USING btree (document_id);


--
-- Name: index_document_events_on_receivable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_events_on_receivable_id ON public.document_events USING btree (receivable_id);


--
-- Name: index_document_events_on_tenant_document_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_events_on_tenant_document_occurred_at ON public.document_events USING btree (tenant_id, document_id, occurred_at);


--
-- Name: index_document_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_events_on_tenant_id ON public.document_events USING btree (tenant_id);


--
-- Name: index_documents_on_actor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_actor_party_id ON public.documents USING btree (actor_party_id);


--
-- Name: index_documents_on_receivable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_receivable_id ON public.documents USING btree (receivable_id);


--
-- Name: index_documents_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_tenant_id ON public.documents USING btree (tenant_id);


--
-- Name: index_documents_on_tenant_id_and_sha256; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_documents_on_tenant_id_and_sha256 ON public.documents USING btree (tenant_id, sha256);


--
-- Name: index_documents_on_tenant_receivable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_tenant_receivable ON public.documents USING btree (tenant_id, receivable_id);


--
-- Name: index_escrow_accounts_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_escrow_accounts_on_party_id ON public.escrow_accounts USING btree (party_id);


--
-- Name: index_escrow_accounts_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_escrow_accounts_on_tenant_id ON public.escrow_accounts USING btree (tenant_id);


--
-- Name: index_escrow_accounts_on_tenant_party_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_escrow_accounts_on_tenant_party_provider ON public.escrow_accounts USING btree (tenant_id, party_id, provider);


--
-- Name: index_escrow_accounts_on_tenant_provider_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_escrow_accounts_on_tenant_provider_account ON public.escrow_accounts USING btree (tenant_id, provider, provider_account_id) WHERE (provider_account_id IS NOT NULL);


--
-- Name: index_escrow_accounts_on_tenant_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_escrow_accounts_on_tenant_status ON public.escrow_accounts USING btree (tenant_id, status);


--
-- Name: index_escrow_payouts_on_anticipation_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_escrow_payouts_on_anticipation_request_id ON public.escrow_payouts USING btree (anticipation_request_id);


--
-- Name: index_escrow_payouts_on_escrow_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_escrow_payouts_on_escrow_account_id ON public.escrow_payouts USING btree (escrow_account_id);


--
-- Name: index_escrow_payouts_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_escrow_payouts_on_party_id ON public.escrow_payouts USING btree (party_id);


--
-- Name: index_escrow_payouts_on_receivable_payment_settlement_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_escrow_payouts_on_receivable_payment_settlement_id ON public.escrow_payouts USING btree (receivable_payment_settlement_id);


--
-- Name: index_escrow_payouts_on_tenant_anticipation_party; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_escrow_payouts_on_tenant_anticipation_party ON public.escrow_payouts USING btree (tenant_id, anticipation_request_id, party_id) WHERE (anticipation_request_id IS NOT NULL);


--
-- Name: index_escrow_payouts_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_escrow_payouts_on_tenant_id ON public.escrow_payouts USING btree (tenant_id);


--
-- Name: index_escrow_payouts_on_tenant_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_escrow_payouts_on_tenant_idempotency_key ON public.escrow_payouts USING btree (tenant_id, idempotency_key);


--
-- Name: index_escrow_payouts_on_tenant_provider_transfer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_escrow_payouts_on_tenant_provider_transfer ON public.escrow_payouts USING btree (tenant_id, provider, provider_transfer_id) WHERE (provider_transfer_id IS NOT NULL);


--
-- Name: index_escrow_payouts_on_tenant_settlement_party; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_escrow_payouts_on_tenant_settlement_party ON public.escrow_payouts USING btree (tenant_id, receivable_payment_settlement_id, party_id) WHERE (receivable_payment_settlement_id IS NOT NULL);


--
-- Name: index_escrow_payouts_on_tenant_status_requested_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_escrow_payouts_on_tenant_status_requested_at ON public.escrow_payouts USING btree (tenant_id, status, requested_at);


--
-- Name: index_hospital_ownerships_on_hospital_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_hospital_ownerships_on_hospital_party_id ON public.hospital_ownerships USING btree (hospital_party_id);


--
-- Name: index_hospital_ownerships_on_organization_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_hospital_ownerships_on_organization_party_id ON public.hospital_ownerships USING btree (organization_party_id);


--
-- Name: index_hospital_ownerships_on_tenant_active_hospital; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_hospital_ownerships_on_tenant_active_hospital ON public.hospital_ownerships USING btree (tenant_id, hospital_party_id) WHERE (active = true);


--
-- Name: index_hospital_ownerships_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_hospital_ownerships_on_tenant_id ON public.hospital_ownerships USING btree (tenant_id);


--
-- Name: index_hospital_ownerships_on_tenant_org_hospital; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_hospital_ownerships_on_tenant_org_hospital ON public.hospital_ownerships USING btree (tenant_id, organization_party_id, hospital_party_id);


--
-- Name: index_kyc_documents_on_kyc_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_documents_on_kyc_profile_id ON public.kyc_documents USING btree (kyc_profile_id);


--
-- Name: index_kyc_documents_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_documents_on_party_id ON public.kyc_documents USING btree (party_id);


--
-- Name: index_kyc_documents_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_documents_on_tenant_id ON public.kyc_documents USING btree (tenant_id);


--
-- Name: index_kyc_events_on_actor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_events_on_actor_party_id ON public.kyc_events USING btree (actor_party_id);


--
-- Name: index_kyc_events_on_kyc_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_events_on_kyc_profile_id ON public.kyc_events USING btree (kyc_profile_id);


--
-- Name: index_kyc_events_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_events_on_party_id ON public.kyc_events USING btree (party_id);


--
-- Name: index_kyc_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_events_on_tenant_id ON public.kyc_events USING btree (tenant_id);


--
-- Name: index_kyc_profiles_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_profiles_on_party_id ON public.kyc_profiles USING btree (party_id);


--
-- Name: index_kyc_profiles_on_reviewer_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_profiles_on_reviewer_party_id ON public.kyc_profiles USING btree (reviewer_party_id);


--
-- Name: index_kyc_profiles_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_kyc_profiles_on_tenant_id ON public.kyc_profiles USING btree (tenant_id);


--
-- Name: index_kyc_profiles_on_tenant_party; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_kyc_profiles_on_tenant_party ON public.kyc_profiles USING btree (tenant_id, party_id);


--
-- Name: index_ledger_entries_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_entries_on_party_id ON public.ledger_entries USING btree (party_id);


--
-- Name: index_ledger_entries_on_receivable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_entries_on_receivable_id ON public.ledger_entries USING btree (receivable_id);


--
-- Name: index_ledger_entries_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_entries_on_tenant_id ON public.ledger_entries USING btree (tenant_id);


--
-- Name: index_ledger_transactions_on_receivable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_transactions_on_receivable_id ON public.ledger_transactions USING btree (receivable_id);


--
-- Name: index_ledger_transactions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_transactions_on_tenant_id ON public.ledger_transactions USING btree (tenant_id);


--
-- Name: index_outbox_dispatch_attempts_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_dispatch_attempts_lookup ON public.outbox_dispatch_attempts USING btree (tenant_id, outbox_event_id, occurred_at);


--
-- Name: index_outbox_dispatch_attempts_on_outbox_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_dispatch_attempts_on_outbox_event_id ON public.outbox_dispatch_attempts USING btree (outbox_event_id);


--
-- Name: index_outbox_dispatch_attempts_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_dispatch_attempts_on_tenant_id ON public.outbox_dispatch_attempts USING btree (tenant_id);


--
-- Name: index_outbox_dispatch_attempts_retry_scan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_dispatch_attempts_retry_scan ON public.outbox_dispatch_attempts USING btree (tenant_id, status, next_attempt_at);


--
-- Name: index_outbox_dispatch_attempts_unique_attempt; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbox_dispatch_attempts_unique_attempt ON public.outbox_dispatch_attempts USING btree (tenant_id, outbox_event_id, attempt_number);


--
-- Name: index_outbox_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_events_on_tenant_id ON public.outbox_events USING btree (tenant_id);


--
-- Name: index_outbox_events_on_tenant_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbox_events_on_tenant_idempotency_key ON public.outbox_events USING btree (tenant_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: index_outbox_events_pending_scan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_events_pending_scan ON public.outbox_events USING btree (tenant_id, status, created_at);


--
-- Name: index_parties_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_parties_on_tenant_id ON public.parties USING btree (tenant_id);


--
-- Name: index_parties_on_tenant_kind_document; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_parties_on_tenant_kind_document ON public.parties USING btree (tenant_id, kind, document_number) WHERE (document_number IS NOT NULL);


--
-- Name: index_parties_on_tenant_kind_external_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_parties_on_tenant_kind_external_ref ON public.parties USING btree (tenant_id, kind, external_ref) WHERE (external_ref IS NOT NULL);


--
-- Name: index_physician_anticipation_authorizations_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_physician_anticipation_authorizations_on_tenant_id ON public.physician_anticipation_authorizations USING btree (tenant_id);


--
-- Name: index_physician_cnpj_split_policies_active_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_physician_cnpj_split_policies_active_unique ON public.physician_cnpj_split_policies USING btree (tenant_id, legal_entity_party_id, scope, status) WHERE ((status)::text = 'ACTIVE'::text);


--
-- Name: index_physician_cnpj_split_policies_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_physician_cnpj_split_policies_lookup ON public.physician_cnpj_split_policies USING btree (tenant_id, legal_entity_party_id, scope, effective_from);


--
-- Name: index_physician_cnpj_split_policies_on_legal_entity_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_physician_cnpj_split_policies_on_legal_entity_party_id ON public.physician_cnpj_split_policies USING btree (legal_entity_party_id);


--
-- Name: index_physician_cnpj_split_policies_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_physician_cnpj_split_policies_on_tenant_id ON public.physician_cnpj_split_policies USING btree (tenant_id);


--
-- Name: index_physician_legal_entity_memberships_on_physician_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_physician_legal_entity_memberships_on_physician_party_id ON public.physician_legal_entity_memberships USING btree (physician_party_id);


--
-- Name: index_physician_legal_entity_memberships_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_physician_legal_entity_memberships_on_tenant_id ON public.physician_legal_entity_memberships USING btree (tenant_id);


--
-- Name: index_physician_memberships_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_physician_memberships_unique ON public.physician_legal_entity_memberships USING btree (tenant_id, physician_party_id, legal_entity_party_id);


--
-- Name: index_physicians_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_physicians_on_party_id ON public.physicians USING btree (party_id);


--
-- Name: index_physicians_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_physicians_on_tenant_id ON public.physicians USING btree (tenant_id);


--
-- Name: index_physicians_on_tenant_id_and_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_physicians_on_tenant_id_and_party_id ON public.physicians USING btree (tenant_id, party_id);


--
-- Name: index_provider_webhook_receipts_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_provider_webhook_receipts_lookup ON public.provider_webhook_receipts USING btree (tenant_id, provider, status, processed_at);


--
-- Name: index_provider_webhook_receipts_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_provider_webhook_receipts_on_tenant_id ON public.provider_webhook_receipts USING btree (tenant_id);


--
-- Name: index_provider_webhook_receipts_unique_event; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_provider_webhook_receipts_unique_event ON public.provider_webhook_receipts USING btree (tenant_id, provider, provider_event_id);


--
-- Name: index_receivable_allocations_on_allocated_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_allocations_on_allocated_party_id ON public.receivable_allocations USING btree (allocated_party_id);


--
-- Name: index_receivable_allocations_on_physician_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_allocations_on_physician_party_id ON public.receivable_allocations USING btree (physician_party_id);


--
-- Name: index_receivable_allocations_on_receivable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_allocations_on_receivable_id ON public.receivable_allocations USING btree (receivable_id);


--
-- Name: index_receivable_allocations_on_receivable_id_and_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_receivable_allocations_on_receivable_id_and_sequence ON public.receivable_allocations USING btree (receivable_id, sequence);


--
-- Name: index_receivable_allocations_on_tenant_allocated_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_allocations_on_tenant_allocated_party ON public.receivable_allocations USING btree (tenant_id, allocated_party_id);


--
-- Name: index_receivable_allocations_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_allocations_on_tenant_id ON public.receivable_allocations USING btree (tenant_id);


--
-- Name: index_receivable_events_on_actor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_events_on_actor_party_id ON public.receivable_events USING btree (actor_party_id);


--
-- Name: index_receivable_events_on_event_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_receivable_events_on_event_hash ON public.receivable_events USING btree (event_hash);


--
-- Name: index_receivable_events_on_receivable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_events_on_receivable_id ON public.receivable_events USING btree (receivable_id);


--
-- Name: index_receivable_events_on_receivable_id_and_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_receivable_events_on_receivable_id_and_sequence ON public.receivable_events USING btree (receivable_id, sequence);


--
-- Name: index_receivable_events_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_events_on_tenant_id ON public.receivable_events USING btree (tenant_id);


--
-- Name: index_receivable_events_on_tenant_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_events_on_tenant_occurred_at ON public.receivable_events USING btree (tenant_id, occurred_at);


--
-- Name: index_receivable_kinds_on_tenant_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_receivable_kinds_on_tenant_and_code ON public.receivable_kinds USING btree (tenant_id, code);


--
-- Name: index_receivable_kinds_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_kinds_on_tenant_id ON public.receivable_kinds USING btree (tenant_id);


--
-- Name: index_receivable_payment_settlements_on_receivable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_payment_settlements_on_receivable_id ON public.receivable_payment_settlements USING btree (receivable_id);


--
-- Name: index_receivable_payment_settlements_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_payment_settlements_on_tenant_id ON public.receivable_payment_settlements USING btree (tenant_id);


--
-- Name: index_receivable_statistics_daily_on_receivable_kind_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_statistics_daily_on_receivable_kind_id ON public.receivable_statistics_daily USING btree (receivable_kind_id);


--
-- Name: index_receivable_statistics_daily_on_scope_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_statistics_daily_on_scope_party_id ON public.receivable_statistics_daily USING btree (scope_party_id);


--
-- Name: index_receivable_statistics_daily_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivable_statistics_daily_on_tenant_id ON public.receivable_statistics_daily USING btree (tenant_id);


--
-- Name: index_receivable_statistics_daily_unique_dimension; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_receivable_statistics_daily_unique_dimension ON public.receivable_statistics_daily USING btree (tenant_id, stat_date, receivable_kind_id, metric_scope, scope_party_id);


--
-- Name: index_receivables_on_beneficiary_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivables_on_beneficiary_party_id ON public.receivables USING btree (beneficiary_party_id);


--
-- Name: index_receivables_on_creditor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivables_on_creditor_party_id ON public.receivables USING btree (creditor_party_id);


--
-- Name: index_receivables_on_debtor_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivables_on_debtor_party_id ON public.receivables USING btree (debtor_party_id);


--
-- Name: index_receivables_on_receivable_kind_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivables_on_receivable_kind_id ON public.receivables USING btree (receivable_kind_id);


--
-- Name: index_receivables_on_tenant_external_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_receivables_on_tenant_external_reference ON public.receivables USING btree (tenant_id, external_reference) WHERE (external_reference IS NOT NULL);


--
-- Name: index_receivables_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivables_on_tenant_id ON public.receivables USING btree (tenant_id);


--
-- Name: index_receivables_on_tenant_status_due_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_receivables_on_tenant_status_due_at ON public.receivables USING btree (tenant_id, status, due_at);


--
-- Name: index_reconciliation_exceptions_on_resolved_by_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reconciliation_exceptions_on_resolved_by_party_id ON public.reconciliation_exceptions USING btree (resolved_by_party_id);


--
-- Name: index_reconciliation_exceptions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reconciliation_exceptions_on_tenant_id ON public.reconciliation_exceptions USING btree (tenant_id);


--
-- Name: index_reconciliation_exceptions_open_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reconciliation_exceptions_open_lookup ON public.reconciliation_exceptions USING btree (tenant_id, status, last_seen_at);


--
-- Name: index_reconciliation_exceptions_unique_signature; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_reconciliation_exceptions_unique_signature ON public.reconciliation_exceptions USING btree (tenant_id, source, provider, external_event_id, code);


--
-- Name: index_roles_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_roles_on_tenant_id ON public.roles USING btree (tenant_id);


--
-- Name: index_roles_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_roles_on_tenant_id_and_code ON public.roles USING btree (tenant_id, code);


--
-- Name: index_sessions_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_tenant_id ON public.sessions USING btree (tenant_id);


--
-- Name: index_sessions_on_tenant_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_tenant_id_and_user_id ON public.sessions USING btree (tenant_id, user_id);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_tenants_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenants_on_slug ON public.tenants USING btree (slug);


--
-- Name: index_user_roles_on_assigned_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_roles_on_assigned_by_user_id ON public.user_roles USING btree (assigned_by_user_id);


--
-- Name: index_user_roles_on_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_roles_on_role_id ON public.user_roles USING btree (role_id);


--
-- Name: index_user_roles_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_roles_on_tenant_id ON public.user_roles USING btree (tenant_id);


--
-- Name: index_user_roles_on_tenant_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_roles_on_tenant_role ON public.user_roles USING btree (tenant_id, role_id);


--
-- Name: index_user_roles_on_tenant_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_roles_on_tenant_user ON public.user_roles USING btree (tenant_id, user_id);


--
-- Name: index_user_roles_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_roles_on_user_id ON public.user_roles USING btree (user_id);


--
-- Name: index_users_on_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_address ON public.users USING btree (email_address);


--
-- Name: index_users_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_party_id ON public.users USING btree (party_id);


--
-- Name: index_users_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_tenant_id ON public.users USING btree (tenant_id);


--
-- Name: index_users_on_tenant_id_and_webauthn_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_tenant_id_and_webauthn_id ON public.users USING btree (tenant_id, webauthn_id) WHERE (webauthn_id IS NOT NULL);


--
-- Name: index_webauthn_credentials_on_tenant_credential; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_webauthn_credentials_on_tenant_credential ON public.webauthn_credentials USING btree (tenant_id, webauthn_id);


--
-- Name: index_webauthn_credentials_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_webauthn_credentials_on_tenant_id ON public.webauthn_credentials USING btree (tenant_id);


--
-- Name: index_webauthn_credentials_on_tenant_user_credential; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_webauthn_credentials_on_tenant_user_credential ON public.webauthn_credentials USING btree (tenant_id, user_id, webauthn_id);


--
-- Name: index_webauthn_credentials_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_webauthn_credentials_on_user_id ON public.webauthn_credentials USING btree (user_id);


--
-- Name: action_ip_logs action_ip_logs_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER action_ip_logs_no_update_delete BEFORE DELETE OR UPDATE ON public.action_ip_logs FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: anticipation_request_events anticipation_request_events_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER anticipation_request_events_no_update_delete BEFORE DELETE OR UPDATE ON public.anticipation_request_events FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: anticipation_requests anticipation_requests_protect_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER anticipation_requests_protect_mutation BEFORE DELETE OR UPDATE ON public.anticipation_requests FOR EACH ROW EXECUTE FUNCTION public.app_protect_anticipation_requests();


--
-- Name: anticipation_settlement_entries anticipation_settlement_entries_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER anticipation_settlement_entries_no_update_delete BEFORE DELETE OR UPDATE ON public.anticipation_settlement_entries FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: document_events document_events_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER document_events_no_update_delete BEFORE DELETE OR UPDATE ON public.document_events FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: kyc_events kyc_events_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER kyc_events_no_update_delete BEFORE DELETE OR UPDATE ON public.kyc_events FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: ledger_entries ledger_entries_balance_check; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_entries_balance_check AFTER INSERT ON public.ledger_entries REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.ledger_entries_check_balance();


--
-- Name: ledger_entries ledger_entries_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_entries_no_update_delete BEFORE DELETE OR UPDATE ON public.ledger_entries FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: ledger_transactions ledger_transactions_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_transactions_no_update_delete BEFORE DELETE OR UPDATE ON public.ledger_transactions FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: outbox_dispatch_attempts outbox_dispatch_attempts_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER outbox_dispatch_attempts_no_update_delete BEFORE DELETE OR UPDATE ON public.outbox_dispatch_attempts FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: outbox_events outbox_events_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER outbox_events_no_update_delete BEFORE DELETE OR UPDATE ON public.outbox_events FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: receivable_events receivable_events_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER receivable_events_no_update_delete BEFORE DELETE OR UPDATE ON public.receivable_events FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: receivable_payment_settlements receivable_payment_settlements_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER receivable_payment_settlements_no_update_delete BEFORE DELETE OR UPDATE ON public.receivable_payment_settlements FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


--
-- Name: ledger_entries fk_ledger_entries_ledger_transactions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT fk_ledger_entries_ledger_transactions FOREIGN KEY (tenant_id, txn_id) REFERENCES public.ledger_transactions(tenant_id, txn_id);


--
-- Name: outbox_events fk_rails_00e6bcedbf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT fk_rails_00e6bcedbf FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: document_events fk_rails_01f495e49f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_events
    ADD CONSTRAINT fk_rails_01f495e49f FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: kyc_profiles fk_rails_03e3cee98f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_profiles
    ADD CONSTRAINT fk_rails_03e3cee98f FOREIGN KEY (reviewer_party_id) REFERENCES public.parties(id);


--
-- Name: assignment_contracts fk_rails_074ac762b1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assignment_contracts
    ADD CONSTRAINT fk_rails_074ac762b1 FOREIGN KEY (assignee_party_id) REFERENCES public.parties(id);


--
-- Name: physician_anticipation_authorizations fk_rails_0ad74647e0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_anticipation_authorizations
    ADD CONSTRAINT fk_rails_0ad74647e0 FOREIGN KEY (beneficiary_physician_party_id) REFERENCES public.parties(id);


--
-- Name: kyc_documents fk_rails_0b286d2adf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_documents
    ADD CONSTRAINT fk_rails_0b286d2adf FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: receivables fk_rails_0cf95cdfff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivables
    ADD CONSTRAINT fk_rails_0cf95cdfff FOREIGN KEY (debtor_party_id) REFERENCES public.parties(id);


--
-- Name: anticipation_requests fk_rails_0fa6e1eef4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_requests
    ADD CONSTRAINT fk_rails_0fa6e1eef4 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: users fk_rails_135c8f54b2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_rails_135c8f54b2 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: kyc_documents fk_rails_13c2597383; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_documents
    ADD CONSTRAINT fk_rails_13c2597383 FOREIGN KEY (kyc_profile_id) REFERENCES public.kyc_profiles(id);


--
-- Name: physician_cnpj_split_policies fk_rails_197298298c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_cnpj_split_policies
    ADD CONSTRAINT fk_rails_197298298c FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: receivable_allocations fk_rails_1b6f950b57; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_allocations
    ADD CONSTRAINT fk_rails_1b6f950b57 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: ledger_entries fk_rails_1d714c27a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT fk_rails_1d714c27a0 FOREIGN KEY (receivable_id) REFERENCES public.receivables(id);


--
-- Name: assignment_contracts fk_rails_1de7571265; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assignment_contracts
    ADD CONSTRAINT fk_rails_1de7571265 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: anticipation_request_events fk_rails_1fb2d6ea67; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_request_events
    ADD CONSTRAINT fk_rails_1fb2d6ea67 FOREIGN KEY (anticipation_request_id) REFERENCES public.anticipation_requests(id);


--
-- Name: escrow_payouts fk_rails_2101940f83; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.escrow_payouts
    ADD CONSTRAINT fk_rails_2101940f83 FOREIGN KEY (escrow_account_id) REFERENCES public.escrow_accounts(id);


--
-- Name: anticipation_request_events fk_rails_213b4b1aba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_request_events
    ADD CONSTRAINT fk_rails_213b4b1aba FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: document_events fk_rails_2226eae8f7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_events
    ADD CONSTRAINT fk_rails_2226eae8f7 FOREIGN KEY (document_id) REFERENCES public.documents(id);


--
-- Name: anticipation_settlement_entries fk_rails_234e4c7c9e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_settlement_entries
    ADD CONSTRAINT fk_rails_234e4c7c9e FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: kyc_events fk_rails_27044fbea3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_events
    ADD CONSTRAINT fk_rails_27044fbea3 FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: anticipation_request_events fk_rails_273612e857; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_request_events
    ADD CONSTRAINT fk_rails_273612e857 FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


--
-- Name: escrow_payouts fk_rails_2bba004179; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.escrow_payouts
    ADD CONSTRAINT fk_rails_2bba004179 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: assignment_contracts fk_rails_3090896c8e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assignment_contracts
    ADD CONSTRAINT fk_rails_3090896c8e FOREIGN KEY (assignor_party_id) REFERENCES public.parties(id);


--
-- Name: user_roles fk_rails_318345354e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT fk_rails_318345354e FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: webauthn_credentials fk_rails_318d45c5d9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webauthn_credentials
    ADD CONSTRAINT fk_rails_318d45c5d9 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: user_roles fk_rails_3369e0d5fc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT fk_rails_3369e0d5fc FOREIGN KEY (role_id) REFERENCES public.roles(id);


--
-- Name: receivables fk_rails_33bc71f297; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivables
    ADD CONSTRAINT fk_rails_33bc71f297 FOREIGN KEY (beneficiary_party_id) REFERENCES public.parties(id);


--
-- Name: receivable_payment_settlements fk_rails_3b061f5f35; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_payment_settlements
    ADD CONSTRAINT fk_rails_3b061f5f35 FOREIGN KEY (receivable_id) REFERENCES public.receivables(id);


--
-- Name: user_roles fk_rails_3b61ce6619; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT fk_rails_3b61ce6619 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: receivable_statistics_daily fk_rails_3c4e69e879; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_statistics_daily
    ADD CONSTRAINT fk_rails_3c4e69e879 FOREIGN KEY (scope_party_id) REFERENCES public.parties(id);


--
-- Name: physician_legal_entity_memberships fk_rails_4202cb5434; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_legal_entity_memberships
    ADD CONSTRAINT fk_rails_4202cb5434 FOREIGN KEY (physician_party_id) REFERENCES public.parties(id);


--
-- Name: physician_legal_entity_memberships fk_rails_4305bfd30e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_legal_entity_memberships
    ADD CONSTRAINT fk_rails_4305bfd30e FOREIGN KEY (legal_entity_party_id) REFERENCES public.parties(id);


--
-- Name: ledger_transactions fk_rails_44cf54fd66; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_transactions
    ADD CONSTRAINT fk_rails_44cf54fd66 FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


--
-- Name: user_roles fk_rails_4cc38d53ec; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT fk_rails_4cc38d53ec FOREIGN KEY (assigned_by_user_id) REFERENCES public.users(id);


--
-- Name: sessions fk_rails_4cc5d929b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_4cc5d929b0 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: documents fk_rails_4fd21ed2d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_4fd21ed2d6 FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


--
-- Name: escrow_accounts fk_rails_51e876299d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.escrow_accounts
    ADD CONSTRAINT fk_rails_51e876299d FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: assignment_contracts fk_rails_5b862aa1fb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assignment_contracts
    ADD CONSTRAINT fk_rails_5b862aa1fb FOREIGN KEY (receivable_id) REFERENCES public.receivables(id);


--
-- Name: documents fk_rails_5ca55da786; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_5ca55da786 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: assignment_contracts fk_rails_5ea04a897c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assignment_contracts
    ADD CONSTRAINT fk_rails_5ea04a897c FOREIGN KEY (anticipation_request_id) REFERENCES public.anticipation_requests(id);


--
-- Name: anticipation_settlement_entries fk_rails_6424d0be1f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_settlement_entries
    ADD CONSTRAINT fk_rails_6424d0be1f FOREIGN KEY (receivable_payment_settlement_id) REFERENCES public.receivable_payment_settlements(id);


--
-- Name: receivables fk_rails_65126c02d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivables
    ADD CONSTRAINT fk_rails_65126c02d6 FOREIGN KEY (receivable_kind_id) REFERENCES public.receivable_kinds(id);


--
-- Name: receivables fk_rails_6f135ab793; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivables
    ADD CONSTRAINT fk_rails_6f135ab793 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: escrow_payouts fk_rails_70a8223ad9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.escrow_payouts
    ADD CONSTRAINT fk_rails_70a8223ad9 FOREIGN KEY (anticipation_request_id) REFERENCES public.anticipation_requests(id);


--
-- Name: kyc_profiles fk_rails_73346608bf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_profiles
    ADD CONSTRAINT fk_rails_73346608bf FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: ledger_entries fk_rails_771b3174f2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT fk_rails_771b3174f2 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: ledger_entries fk_rails_787e0031ca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT fk_rails_787e0031ca FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: hospital_ownerships fk_rails_78d7de9ce4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hospital_ownerships
    ADD CONSTRAINT fk_rails_78d7de9ce4 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: provider_webhook_receipts fk_rails_7ac28905bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_webhook_receipts
    ADD CONSTRAINT fk_rails_7ac28905bd FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: documents fk_rails_7b301b6135; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_7b301b6135 FOREIGN KEY (receivable_id) REFERENCES public.receivables(id);


--
-- Name: parties fk_rails_80063aae17; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT fk_rails_80063aae17 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: receivable_events fk_rails_8228e3bde7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_events
    ADD CONSTRAINT fk_rails_8228e3bde7 FOREIGN KEY (receivable_id) REFERENCES public.receivables(id);


--
-- Name: receivable_allocations fk_rails_82ec2d14fa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_allocations
    ADD CONSTRAINT fk_rails_82ec2d14fa FOREIGN KEY (allocated_party_id) REFERENCES public.parties(id);


--
-- Name: receivable_allocations fk_rails_88137cd788; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_allocations
    ADD CONSTRAINT fk_rails_88137cd788 FOREIGN KEY (receivable_id) REFERENCES public.receivables(id);


--
-- Name: physicians fk_rails_8df6e967db; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physicians
    ADD CONSTRAINT fk_rails_8df6e967db FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: outbox_dispatch_attempts fk_rails_8f3b2f527d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_dispatch_attempts
    ADD CONSTRAINT fk_rails_8f3b2f527d FOREIGN KEY (outbox_event_id) REFERENCES public.outbox_events(id);


--
-- Name: physician_cnpj_split_policies fk_rails_91a5618ab5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_cnpj_split_policies
    ADD CONSTRAINT fk_rails_91a5618ab5 FOREIGN KEY (legal_entity_party_id) REFERENCES public.parties(id);


--
-- Name: receivable_statistics_daily fk_rails_9402cb82a3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_statistics_daily
    ADD CONSTRAINT fk_rails_9402cb82a3 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: escrow_payouts fk_rails_953aa6c15d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.escrow_payouts
    ADD CONSTRAINT fk_rails_953aa6c15d FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: receivable_allocations fk_rails_95ffa4a06a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_allocations
    ADD CONSTRAINT fk_rails_95ffa4a06a FOREIGN KEY (physician_party_id) REFERENCES public.parties(id);


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: physicians fk_rails_9f3467f1e8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physicians
    ADD CONSTRAINT fk_rails_9f3467f1e8 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: action_ip_logs fk_rails_9fad85dfe8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.action_ip_logs
    ADD CONSTRAINT fk_rails_9fad85dfe8 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: physician_anticipation_authorizations fk_rails_a3334b1e81; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_anticipation_authorizations
    ADD CONSTRAINT fk_rails_a3334b1e81 FOREIGN KEY (legal_entity_party_id) REFERENCES public.parties(id);


--
-- Name: webauthn_credentials fk_rails_a4355aef77; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webauthn_credentials
    ADD CONSTRAINT fk_rails_a4355aef77 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: document_events fk_rails_a48600c54d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_events
    ADD CONSTRAINT fk_rails_a48600c54d FOREIGN KEY (receivable_id) REFERENCES public.receivables(id);


--
-- Name: kyc_profiles fk_rails_aa8110c452; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_profiles
    ADD CONSTRAINT fk_rails_aa8110c452 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: auth_challenges fk_rails_b664f3fd7a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_challenges
    ADD CONSTRAINT fk_rails_b664f3fd7a FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


--
-- Name: physician_anticipation_authorizations fk_rails_b6e92b681c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_anticipation_authorizations
    ADD CONSTRAINT fk_rails_b6e92b681c FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: physician_legal_entity_memberships fk_rails_b701c5767e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_legal_entity_memberships
    ADD CONSTRAINT fk_rails_b701c5767e FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: reconciliation_exceptions fk_rails_b72d8d7c17; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_exceptions
    ADD CONSTRAINT fk_rails_b72d8d7c17 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: physician_anticipation_authorizations fk_rails_ba60c25252; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physician_anticipation_authorizations
    ADD CONSTRAINT fk_rails_ba60c25252 FOREIGN KEY (granted_by_membership_id) REFERENCES public.physician_legal_entity_memberships(id);


--
-- Name: receivable_events fk_rails_bfbecb296b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_events
    ADD CONSTRAINT fk_rails_bfbecb296b FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: kyc_documents fk_rails_cb866af6de; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_documents
    ADD CONSTRAINT fk_rails_cb866af6de FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: anticipation_requests fk_rails_cc45595c27; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_requests
    ADD CONSTRAINT fk_rails_cc45595c27 FOREIGN KEY (receivable_allocation_id) REFERENCES public.receivable_allocations(id);


--
-- Name: reconciliation_exceptions fk_rails_cc94151447; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_exceptions
    ADD CONSTRAINT fk_rails_cc94151447 FOREIGN KEY (resolved_by_party_id) REFERENCES public.parties(id);


--
-- Name: anticipation_requests fk_rails_ccb2e14c7b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_requests
    ADD CONSTRAINT fk_rails_ccb2e14c7b FOREIGN KEY (receivable_id) REFERENCES public.receivables(id);


--
-- Name: document_events fk_rails_ce4da09b76; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_events
    ADD CONSTRAINT fk_rails_ce4da09b76 FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


--
-- Name: auth_challenges fk_rails_cf1d7f6918; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_challenges
    ADD CONSTRAINT fk_rails_cf1d7f6918 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: receivable_statistics_daily fk_rails_d1268622c3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_statistics_daily
    ADD CONSTRAINT fk_rails_d1268622c3 FOREIGN KEY (receivable_kind_id) REFERENCES public.receivable_kinds(id);


--
-- Name: escrow_accounts fk_rails_d20f9dda89; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.escrow_accounts
    ADD CONSTRAINT fk_rails_d20f9dda89 FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: anticipation_settlement_entries fk_rails_d52c753781; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_settlement_entries
    ADD CONSTRAINT fk_rails_d52c753781 FOREIGN KEY (anticipation_request_id) REFERENCES public.anticipation_requests(id);


--
-- Name: roles fk_rails_d7321fcec4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT fk_rails_d7321fcec4 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: receivable_events fk_rails_d9606ecce3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_events
    ADD CONSTRAINT fk_rails_d9606ecce3 FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


--
-- Name: ledger_transactions fk_rails_d9cb72cfef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_transactions
    ADD CONSTRAINT fk_rails_d9cb72cfef FOREIGN KEY (receivable_id) REFERENCES public.receivables(id);


--
-- Name: escrow_payouts fk_rails_dac8141e84; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.escrow_payouts
    ADD CONSTRAINT fk_rails_dac8141e84 FOREIGN KEY (receivable_payment_settlement_id) REFERENCES public.receivable_payment_settlements(id);


--
-- Name: ledger_transactions fk_rails_dae13efe9e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_transactions
    ADD CONSTRAINT fk_rails_dae13efe9e FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: hospital_ownerships fk_rails_dfbe05a360; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hospital_ownerships
    ADD CONSTRAINT fk_rails_dfbe05a360 FOREIGN KEY (organization_party_id) REFERENCES public.parties(id);


--
-- Name: receivable_payment_settlements fk_rails_e00f64e3bb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_payment_settlements
    ADD CONSTRAINT fk_rails_e00f64e3bb FOREIGN KEY (receivable_allocation_id) REFERENCES public.receivable_allocations(id);


--
-- Name: users fk_rails_e182934c1f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_rails_e182934c1f FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: kyc_events fk_rails_e4f8915eb5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_events
    ADD CONSTRAINT fk_rails_e4f8915eb5 FOREIGN KEY (kyc_profile_id) REFERENCES public.kyc_profiles(id);


--
-- Name: receivable_kinds fk_rails_e887785ef5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_kinds
    ADD CONSTRAINT fk_rails_e887785ef5 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: receivables fk_rails_e8f5ade4c1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivables
    ADD CONSTRAINT fk_rails_e8f5ade4c1 FOREIGN KEY (creditor_party_id) REFERENCES public.parties(id);


--
-- Name: anticipation_requests fk_rails_ec1b541787; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_requests
    ADD CONSTRAINT fk_rails_ec1b541787 FOREIGN KEY (requester_party_id) REFERENCES public.parties(id);


--
-- Name: kyc_events fk_rails_ec4f06e4bf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_events
    ADD CONSTRAINT fk_rails_ec4f06e4bf FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: outbox_dispatch_attempts fk_rails_ec88541833; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_dispatch_attempts
    ADD CONSTRAINT fk_rails_ec88541833 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: action_ip_logs fk_rails_f0fed210ec; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.action_ip_logs
    ADD CONSTRAINT fk_rails_f0fed210ec FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


--
-- Name: api_access_tokens fk_rails_f405a7988d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_access_tokens
    ADD CONSTRAINT fk_rails_f405a7988d FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: api_access_tokens fk_rails_f4c304228b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_access_tokens
    ADD CONSTRAINT fk_rails_f4c304228b FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: hospital_ownerships fk_rails_f6aaec8d46; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hospital_ownerships
    ADD CONSTRAINT fk_rails_f6aaec8d46 FOREIGN KEY (hospital_party_id) REFERENCES public.parties(id);


--
-- Name: kyc_events fk_rails_f825b108d5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kyc_events
    ADD CONSTRAINT fk_rails_f825b108d5 FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


--
-- Name: receivable_payment_settlements fk_rails_fa4bc9a432; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_payment_settlements
    ADD CONSTRAINT fk_rails_fa4bc9a432 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: action_ip_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.action_ip_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: action_ip_logs action_ip_logs_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY action_ip_logs_tenant_policy ON public.action_ip_logs USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: active_storage_attachments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.active_storage_attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: active_storage_attachments active_storage_attachments_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_storage_attachments_tenant_policy ON public.active_storage_attachments USING ((EXISTS ( SELECT 1
   FROM public.active_storage_blobs blobs
  WHERE ((blobs.id = active_storage_attachments.blob_id) AND (public.app_active_storage_blob_tenant_id(blobs.metadata) = public.app_current_tenant_id()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.active_storage_blobs blobs
  WHERE ((blobs.id = active_storage_attachments.blob_id) AND (public.app_active_storage_blob_tenant_id(blobs.metadata) = public.app_current_tenant_id())))));


--
-- Name: active_storage_blobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.active_storage_blobs ENABLE ROW LEVEL SECURITY;

--
-- Name: active_storage_blobs active_storage_blobs_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_storage_blobs_tenant_policy ON public.active_storage_blobs USING ((public.app_active_storage_blob_tenant_id(metadata) = public.app_current_tenant_id())) WITH CHECK ((public.app_active_storage_blob_tenant_id(metadata) = public.app_current_tenant_id()));


--
-- Name: active_storage_variant_records; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.active_storage_variant_records ENABLE ROW LEVEL SECURITY;

--
-- Name: active_storage_variant_records active_storage_variant_records_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_storage_variant_records_tenant_policy ON public.active_storage_variant_records USING ((EXISTS ( SELECT 1
   FROM public.active_storage_blobs blobs
  WHERE ((blobs.id = active_storage_variant_records.blob_id) AND (public.app_active_storage_blob_tenant_id(blobs.metadata) = public.app_current_tenant_id()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.active_storage_blobs blobs
  WHERE ((blobs.id = active_storage_variant_records.blob_id) AND (public.app_active_storage_blob_tenant_id(blobs.metadata) = public.app_current_tenant_id())))));


--
-- Name: anticipation_request_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.anticipation_request_events ENABLE ROW LEVEL SECURITY;

--
-- Name: anticipation_request_events anticipation_request_events_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY anticipation_request_events_tenant_policy ON public.anticipation_request_events USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: anticipation_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.anticipation_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: anticipation_requests anticipation_requests_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY anticipation_requests_tenant_policy ON public.anticipation_requests USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: anticipation_settlement_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.anticipation_settlement_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: anticipation_settlement_entries anticipation_settlement_entries_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY anticipation_settlement_entries_tenant_policy ON public.anticipation_settlement_entries USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: api_access_tokens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.api_access_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: api_access_tokens api_access_tokens_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY api_access_tokens_tenant_policy ON public.api_access_tokens USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: assignment_contracts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.assignment_contracts ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_contracts assignment_contracts_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY assignment_contracts_tenant_policy ON public.assignment_contracts USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: auth_challenges; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.auth_challenges ENABLE ROW LEVEL SECURITY;

--
-- Name: auth_challenges auth_challenges_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY auth_challenges_tenant_policy ON public.auth_challenges USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: document_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_events ENABLE ROW LEVEL SECURITY;

--
-- Name: document_events document_events_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_events_tenant_policy ON public.document_events USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;

--
-- Name: documents documents_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY documents_tenant_policy ON public.documents USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: escrow_accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.escrow_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: escrow_accounts escrow_accounts_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escrow_accounts_tenant_policy ON public.escrow_accounts USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: escrow_payouts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.escrow_payouts ENABLE ROW LEVEL SECURITY;

--
-- Name: escrow_payouts escrow_payouts_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY escrow_payouts_tenant_policy ON public.escrow_payouts USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: hospital_ownerships; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hospital_ownerships ENABLE ROW LEVEL SECURITY;

--
-- Name: hospital_ownerships hospital_ownerships_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hospital_ownerships_tenant_policy ON public.hospital_ownerships USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: kyc_documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.kyc_documents ENABLE ROW LEVEL SECURITY;

--
-- Name: kyc_documents kyc_documents_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY kyc_documents_tenant_policy ON public.kyc_documents USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: kyc_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.kyc_events ENABLE ROW LEVEL SECURITY;

--
-- Name: kyc_events kyc_events_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY kyc_events_tenant_policy ON public.kyc_events USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: kyc_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.kyc_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: kyc_profiles kyc_profiles_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY kyc_profiles_tenant_policy ON public.kyc_profiles USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: ledger_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: ledger_entries ledger_entries_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ledger_entries_tenant_policy ON public.ledger_entries USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: ledger_transactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ledger_transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: ledger_transactions ledger_transactions_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ledger_transactions_tenant_policy ON public.ledger_transactions USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: outbox_dispatch_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.outbox_dispatch_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: outbox_dispatch_attempts outbox_dispatch_attempts_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY outbox_dispatch_attempts_tenant_policy ON public.outbox_dispatch_attempts USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: outbox_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.outbox_events ENABLE ROW LEVEL SECURITY;

--
-- Name: outbox_events outbox_events_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY outbox_events_tenant_policy ON public.outbox_events USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: parties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.parties ENABLE ROW LEVEL SECURITY;

--
-- Name: parties parties_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY parties_tenant_policy ON public.parties USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: physician_anticipation_authorizations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.physician_anticipation_authorizations ENABLE ROW LEVEL SECURITY;

--
-- Name: physician_anticipation_authorizations physician_anticipation_authorizations_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY physician_anticipation_authorizations_tenant_policy ON public.physician_anticipation_authorizations USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: physician_cnpj_split_policies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.physician_cnpj_split_policies ENABLE ROW LEVEL SECURITY;

--
-- Name: physician_cnpj_split_policies physician_cnpj_split_policies_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY physician_cnpj_split_policies_tenant_policy ON public.physician_cnpj_split_policies USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: physician_legal_entity_memberships; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.physician_legal_entity_memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: physician_legal_entity_memberships physician_legal_entity_memberships_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY physician_legal_entity_memberships_tenant_policy ON public.physician_legal_entity_memberships USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: physicians; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.physicians ENABLE ROW LEVEL SECURITY;

--
-- Name: physicians physicians_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY physicians_tenant_policy ON public.physicians USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: provider_webhook_receipts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.provider_webhook_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: provider_webhook_receipts provider_webhook_receipts_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY provider_webhook_receipts_tenant_policy ON public.provider_webhook_receipts USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: receivable_allocations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.receivable_allocations ENABLE ROW LEVEL SECURITY;

--
-- Name: receivable_allocations receivable_allocations_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receivable_allocations_tenant_policy ON public.receivable_allocations USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: receivable_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.receivable_events ENABLE ROW LEVEL SECURITY;

--
-- Name: receivable_events receivable_events_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receivable_events_tenant_policy ON public.receivable_events USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: receivable_kinds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.receivable_kinds ENABLE ROW LEVEL SECURITY;

--
-- Name: receivable_kinds receivable_kinds_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receivable_kinds_tenant_policy ON public.receivable_kinds USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: receivable_payment_settlements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.receivable_payment_settlements ENABLE ROW LEVEL SECURITY;

--
-- Name: receivable_payment_settlements receivable_payment_settlements_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receivable_payment_settlements_tenant_policy ON public.receivable_payment_settlements USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: receivable_statistics_daily; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.receivable_statistics_daily ENABLE ROW LEVEL SECURITY;

--
-- Name: receivable_statistics_daily receivable_statistics_daily_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receivable_statistics_daily_tenant_policy ON public.receivable_statistics_daily USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: receivables; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.receivables ENABLE ROW LEVEL SECURITY;

--
-- Name: receivables receivables_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receivables_tenant_policy ON public.receivables USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: reconciliation_exceptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reconciliation_exceptions ENABLE ROW LEVEL SECURITY;

--
-- Name: reconciliation_exceptions reconciliation_exceptions_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reconciliation_exceptions_tenant_policy ON public.reconciliation_exceptions USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

--
-- Name: roles roles_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_tenant_policy ON public.roles USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: sessions sessions_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sessions_tenant_policy ON public.sessions USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: tenants; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;

--
-- Name: tenants tenants_ops_admin_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenants_ops_admin_policy ON public.tenants FOR SELECT USING ((current_setting('app.role'::text, true) = 'ops_admin'::text));


--
-- Name: tenants tenants_self_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenants_self_policy ON public.tenants USING ((id = public.app_current_tenant_id())) WITH CHECK ((id = public.app_current_tenant_id()));


--
-- Name: tenants tenants_slug_lookup_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenants_slug_lookup_policy ON public.tenants FOR SELECT USING (((current_setting('app.allow_tenant_slug_lookup'::text, true) = 'true'::text) AND ((slug)::text = NULLIF(current_setting('app.requested_tenant_slug'::text, true), ''::text)) AND (active = true)));


--
-- Name: user_roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

--
-- Name: user_roles user_roles_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_roles_tenant_policy ON public.user_roles USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: users users_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_tenant_policy ON public.users USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- Name: webauthn_credentials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.webauthn_credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: webauthn_credentials webauthn_credentials_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY webauthn_credentials_tenant_policy ON public.webauthn_credentials USING ((tenant_id = public.app_current_tenant_id())) WITH CHECK ((tenant_id = public.app_current_tenant_id()));


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260219193000'),
('20260219182000'),
('20260219174000'),
('20260219170000'),
('20260219160000'),
('20260219153000'),
('20260219124000'),
('20260219123000'),
('20260219110000'),
('20260214152000'),
('20260214151000'),
('20260214145000'),
('20260214144000'),
('20260214143000'),
('20260214130000'),
('20260214120000'),
('20260214113000'),
('20260214102000'),
('20260214101000'),
('20260213212700'),
('20260213133000'),
('20260213124000'),
('20260213123000'),
('20260213115000'),
('20260213114000'),
('20260213113000'),
('20260213100000'),
('20260210213000'),
('20260210200500'),
('20260210195500'),
('20260210193000'),
('20260210190000'),
('20260210170000'),
('20260210160001'),
('20260210160000'),
('20260210144820'),
('20260210144819'),
('20260210113000');

