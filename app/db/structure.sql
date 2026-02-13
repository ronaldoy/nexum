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
-- Name: ledger_entries_check_balance(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ledger_entries_check_balance() RETURNS trigger
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
    CONSTRAINT action_ip_logs_channel_check CHECK (((channel)::text = ANY ((ARRAY['API'::character varying, 'PORTAL'::character varying, 'WORKER'::character varying, 'WEBHOOK'::character varying, 'ADMIN'::character varying])::text[])))
);

ALTER TABLE ONLY public.action_ip_logs FORCE ROW LEVEL SECURITY;


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
    CONSTRAINT anticipation_requests_channel_check CHECK (((channel)::text = ANY ((ARRAY['API'::character varying, 'PORTAL'::character varying, 'WEBHOOK'::character varying, 'INTERNAL'::character varying])::text[]))),
    CONSTRAINT anticipation_requests_discount_amount_check CHECK ((discount_amount >= (0)::numeric)),
    CONSTRAINT anticipation_requests_discount_rate_check CHECK ((discount_rate >= (0)::numeric)),
    CONSTRAINT anticipation_requests_net_amount_positive_check CHECK ((net_amount > (0)::numeric)),
    CONSTRAINT anticipation_requests_requested_amount_positive_check CHECK ((requested_amount > (0)::numeric)),
    CONSTRAINT anticipation_requests_status_check CHECK (((status)::text = ANY ((ARRAY['REQUESTED'::character varying, 'APPROVED'::character varying, 'FUNDED'::character varying, 'SETTLED'::character varying, 'CANCELLED'::character varying, 'REJECTED'::character varying])::text[])))
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
    CONSTRAINT auth_challenges_delivery_channel_check CHECK (((delivery_channel)::text = ANY ((ARRAY['EMAIL'::character varying, 'WHATSAPP'::character varying])::text[]))),
    CONSTRAINT auth_challenges_max_attempts_check CHECK ((max_attempts > 0)),
    CONSTRAINT auth_challenges_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'VERIFIED'::character varying, 'EXPIRED'::character varying, 'CANCELLED'::character varying])::text[])))
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
    CONSTRAINT documents_status_check CHECK (((status)::text = ANY ((ARRAY['SIGNED'::character varying, 'REVOKED'::character varying, 'SUPERSEDED'::character varying])::text[])))
);

ALTER TABLE ONLY public.documents FORCE ROW LEVEL SECURITY;


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
    CONSTRAINT kyc_documents_document_type_check CHECK (((document_type)::text = ANY ((ARRAY['CPF'::character varying, 'CNPJ'::character varying, 'RG'::character varying, 'CNH'::character varying, 'PASSPORT'::character varying, 'PROOF_OF_ADDRESS'::character varying, 'SELFIE'::character varying, 'CONTRACT'::character varying, 'OTHER'::character varying])::text[]))),
    CONSTRAINT kyc_documents_issuing_state_check CHECK (((issuing_state IS NULL) OR ((issuing_state)::text = ANY ((ARRAY['AC'::character varying, 'AL'::character varying, 'AP'::character varying, 'AM'::character varying, 'BA'::character varying, 'CE'::character varying, 'DF'::character varying, 'ES'::character varying, 'GO'::character varying, 'MA'::character varying, 'MT'::character varying, 'MS'::character varying, 'MG'::character varying, 'PA'::character varying, 'PB'::character varying, 'PR'::character varying, 'PE'::character varying, 'PI'::character varying, 'RJ'::character varying, 'RN'::character varying, 'RS'::character varying, 'RO'::character varying, 'RR'::character varying, 'SC'::character varying, 'SP'::character varying, 'SE'::character varying, 'TO'::character varying])::text[])))),
    CONSTRAINT kyc_documents_key_document_type_check CHECK (((NOT is_key_document) OR ((document_type)::text = ANY ((ARRAY['CPF'::character varying, 'CNPJ'::character varying])::text[])))),
    CONSTRAINT kyc_documents_non_key_identity_docs_check CHECK ((((document_type)::text <> ALL ((ARRAY['RG'::character varying, 'CNH'::character varying, 'PASSPORT'::character varying])::text[])) OR (is_key_document = false))),
    CONSTRAINT kyc_documents_sha256_present_check CHECK ((char_length((sha256)::text) > 0)),
    CONSTRAINT kyc_documents_status_check CHECK (((status)::text = ANY ((ARRAY['SUBMITTED'::character varying, 'VERIFIED'::character varying, 'REJECTED'::character varying, 'EXPIRED'::character varying])::text[]))),
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
    CONSTRAINT kyc_profiles_risk_level_check CHECK (((risk_level)::text = ANY ((ARRAY['UNKNOWN'::character varying, 'LOW'::character varying, 'MEDIUM'::character varying, 'HIGH'::character varying])::text[]))),
    CONSTRAINT kyc_profiles_status_check CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'PENDING_REVIEW'::character varying, 'NEEDS_INFORMATION'::character varying, 'APPROVED'::character varying, 'REJECTED'::character varying])::text[])))
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
    CONSTRAINT ledger_entries_amount_positive_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT ledger_entries_currency_brl_check CHECK (((currency)::text = 'BRL'::text)),
    CONSTRAINT ledger_entries_entry_side_check CHECK (((entry_side)::text = ANY ((ARRAY['DEBIT'::character varying, 'CREDIT'::character varying])::text[])))
);

ALTER TABLE ONLY public.ledger_entries FORCE ROW LEVEL SECURITY;


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
    CONSTRAINT outbox_events_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'SENT'::character varying, 'FAILED'::character varying, 'CANCELLED'::character varying])::text[])))
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
    CONSTRAINT parties_document_type_check CHECK (((document_type)::text = ANY ((ARRAY['CPF'::character varying, 'CNPJ'::character varying])::text[]))),
    CONSTRAINT parties_document_type_kind_check CHECK (((((kind)::text = 'PHYSICIAN_PF'::text) AND ((document_type)::text = 'CPF'::text)) OR (((kind)::text <> 'PHYSICIAN_PF'::text) AND ((document_type)::text = 'CNPJ'::text)))),
    CONSTRAINT parties_kind_check CHECK (((kind)::text = ANY ((ARRAY['HOSPITAL'::character varying, 'SUPPLIER'::character varying, 'PHYSICIAN_PF'::character varying, 'LEGAL_ENTITY_PJ'::character varying, 'FIDC'::character varying, 'PLATFORM'::character varying])::text[])))
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
    CONSTRAINT physician_authorization_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'REVOKED'::character varying, 'EXPIRED'::character varying])::text[])))
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
    CONSTRAINT physician_cnpj_split_policies_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[]))),
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
    CONSTRAINT physician_membership_role_check CHECK (((membership_role)::text = ANY ((ARRAY['ADMIN'::character varying, 'MEMBER'::character varying])::text[]))),
    CONSTRAINT physician_membership_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
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
    CONSTRAINT physicians_crm_state_check CHECK (((crm_state IS NULL) OR ((crm_state)::text = ANY ((ARRAY['AC'::character varying, 'AL'::character varying, 'AP'::character varying, 'AM'::character varying, 'BA'::character varying, 'CE'::character varying, 'DF'::character varying, 'ES'::character varying, 'GO'::character varying, 'MA'::character varying, 'MT'::character varying, 'MS'::character varying, 'MG'::character varying, 'PA'::character varying, 'PB'::character varying, 'PR'::character varying, 'PE'::character varying, 'PI'::character varying, 'RJ'::character varying, 'RN'::character varying, 'RS'::character varying, 'RO'::character varying, 'RR'::character varying, 'SC'::character varying, 'SP'::character varying, 'SE'::character varying, 'TO'::character varying])::text[]))))
);

ALTER TABLE ONLY public.physicians FORCE ROW LEVEL SECURITY;


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
    CONSTRAINT receivable_allocations_status_check CHECK (((status)::text = ANY ((ARRAY['OPEN'::character varying, 'SETTLED'::character varying, 'CANCELLED'::character varying])::text[]))),
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
    CONSTRAINT receivable_kinds_source_family_check CHECK (((source_family)::text = ANY ((ARRAY['PHYSICIAN'::character varying, 'SUPPLIER'::character varying, 'OTHER'::character varying])::text[])))
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
    payment_reference character varying,
    request_id character varying,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT receivable_payment_settlements_beneficiary_non_negative_check CHECK ((beneficiary_amount >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_cnpj_non_negative_check CHECK ((cnpj_amount >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_fdic_after_non_negative_check CHECK ((fdic_balance_after >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_fdic_balance_flow_check CHECK ((fdic_balance_before >= fdic_balance_after)),
    CONSTRAINT receivable_payment_settlements_fdic_before_non_negative_check CHECK ((fdic_balance_before >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_fdic_non_negative_check CHECK ((fdic_amount >= (0)::numeric)),
    CONSTRAINT receivable_payment_settlements_paid_positive_check CHECK ((paid_amount > (0)::numeric)),
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
    CONSTRAINT receivable_statistics_daily_metric_scope_check CHECK (((metric_scope)::text = ANY ((ARRAY['GLOBAL'::character varying, 'DEBTOR'::character varying, 'CREDITOR'::character varying, 'BENEFICIARY'::character varying])::text[])))
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
    CONSTRAINT receivables_status_check CHECK (((status)::text = ANY ((ARRAY['PERFORMED'::character varying, 'ANTICIPATION_REQUESTED'::character varying, 'FUNDED'::character varying, 'SETTLED'::character varying, 'CANCELLED'::character varying])::text[])))
);

ALTER TABLE ONLY public.receivables FORCE ROW LEVEL SECURITY;


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
    updated_at timestamp(6) without time zone NOT NULL
);


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
    role character varying DEFAULT 'supplier_user'::character varying NOT NULL
);


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
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


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
-- Name: idx_rps_tenant_payment_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rps_tenant_payment_ref ON public.receivable_payment_settlements USING btree (tenant_id, payment_reference) WHERE (payment_reference IS NOT NULL);


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
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_tenants_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenants_on_slug ON public.tenants USING btree (slug);


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
-- Name: action_ip_logs action_ip_logs_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER action_ip_logs_no_update_delete BEFORE DELETE OR UPDATE ON public.action_ip_logs FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


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

CREATE CONSTRAINT TRIGGER ledger_entries_balance_check AFTER INSERT ON public.ledger_entries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.ledger_entries_check_balance();


--
-- Name: ledger_entries ledger_entries_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_entries_no_update_delete BEFORE DELETE OR UPDATE ON public.ledger_entries FOR EACH ROW EXECUTE FUNCTION public.app_forbid_mutation();


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
-- Name: documents fk_rails_4fd21ed2d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_4fd21ed2d6 FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


--
-- Name: documents fk_rails_5ca55da786; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_5ca55da786 FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


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
-- Name: receivable_allocations fk_rails_95ffa4a06a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_allocations
    ADD CONSTRAINT fk_rails_95ffa4a06a FOREIGN KEY (physician_party_id) REFERENCES public.parties(id);


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
-- Name: anticipation_settlement_entries fk_rails_d52c753781; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anticipation_settlement_entries
    ADD CONSTRAINT fk_rails_d52c753781 FOREIGN KEY (anticipation_request_id) REFERENCES public.anticipation_requests(id);


--
-- Name: receivable_events fk_rails_d9606ecce3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receivable_events
    ADD CONSTRAINT fk_rails_d9606ecce3 FOREIGN KEY (actor_party_id) REFERENCES public.parties(id);


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
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
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

