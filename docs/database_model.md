# Database Model Documentation

Generated at: 2026-02-19T18:45:32-03:00
Source schema: `app/db/structure.sql`

## Summary

- Total tables documented: 43
- Tables with append-only mutation guard: 11
- Business timezone: `America/Sao_Paulo`

## `action_ip_logs`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `action_ip_logs_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `actor_party_id` | `uuid` | true | `` | `parties.id` |
| `action_type` | `character varying` | false | `` | - |
| `ip_address` | `inet` | false | `` | - |
| `user_agent` | `character varying` | true | `` | - |
| `request_id` | `character varying` | true | `` | - |
| `endpoint_path` | `character varying` | true | `` | - |
| `http_method` | `character varying` | true | `` | - |
| `channel` | `character varying` | false | `` | - |
| `target_type` | `character varying` | true | `` | - |
| `target_id` | `uuid` | true | `` | - |
| `success` | `boolean` | false | `true` | - |
| `occurred_at` | `timestamp(6) without time zone` | false | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `action_ip_logs_channel_check`: `channel::text = ANY (ARRAY['API'::character varying::text, 'PORTAL'::character varying::text, 'WORKER'::character varying::text, 'WEBHOOK'::character varying::text, 'ADMIN'::character varying::text])`

### Indexes

- `index_action_ip_logs_on_actor_party_id` (non-unique): `actor_party_id`
- `index_action_ip_logs_on_tenant_actor_occurred_at` (non-unique): `tenant_id, actor_party_id, occurred_at`
- `index_action_ip_logs_on_tenant_id` (non-unique): `tenant_id`
- `index_action_ip_logs_on_tenant_occurred_at` (non-unique): `tenant_id, occurred_at`
- `index_action_ip_logs_on_tenant_request_id` (non-unique): `tenant_id, request_id`

## `active_storage_attachments`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `active_storage_attachments_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `bigint` | false | `` | - |
| `name` | `character varying` | false | `` | - |
| `record_type` | `character varying` | false | `` | - |
| `record_id` | `text` | false | `` | - |
| `blob_id` | `bigint` | false | `` | `active_storage_blobs.id` |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |

### Indexes

- `index_active_storage_attachments_on_blob_id` (non-unique): `blob_id`
- `index_active_storage_attachments_uniqueness` (unique): `record_type, record_id, name, blob_id`

## `active_storage_blobs`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `active_storage_blobs_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `bigint` | false | `` | - |
| `key` | `character varying` | false | `` | - |
| `filename` | `character varying` | false | `` | - |
| `content_type` | `character varying` | true | `` | - |
| `metadata` | `text` | true | `` | - |
| `service_name` | `character varying` | false | `` | - |
| `byte_size` | `bigint` | false | `` | - |
| `checksum` | `character varying` | true | `` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |

### Indexes

- `index_active_storage_blobs_on_key` (unique): `key`
- `index_active_storage_blobs_on_tenant_direct_upload_idempotency` (unique): `app_active_storage_blob_tenant_id(metadata), ((app_active_storage_blob_metadata_json(metadata) ->> 'direct_upload_idempotency_key'::text))` WHERE ((app_active_storage_blob_tenant_id(metadata) IS NOT NULL) AND (COALESCE((app_active_storage_blob_metadata_json(metadata) ->> 'direct_upload_idempotency_key'::text), ''::text) <> ''::text))

## `active_storage_variant_records`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `active_storage_variant_records_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `bigint` | false | `` | - |
| `blob_id` | `bigint` | false | `` | `active_storage_blobs.id` |
| `variation_digest` | `character varying` | false | `` | - |

### Indexes

- `index_active_storage_variant_records_uniqueness` (unique): `blob_id, variation_digest`

## `anticipation_request_events`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `anticipation_request_events_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `anticipation_request_id` | `uuid` | false | `` | `anticipation_requests.id` |
| `sequence` | `integer` | false | `` | - |
| `event_type` | `character varying` | false | `` | - |
| `status_before` | `character varying` | true | `` | - |
| `status_after` | `character varying` | true | `` | - |
| `actor_party_id` | `uuid` | true | `` | `parties.id` |
| `actor_role` | `character varying` | true | `` | - |
| `request_id` | `character varying` | true | `` | - |
| `occurred_at` | `timestamp(6) without time zone` | false | `` | - |
| `prev_hash` | `character varying` | true | `` | - |
| `event_hash` | `character varying` | false | `` | - |
| `payload` | `jsonb` | true | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Indexes

- `idx_anticipation_request_events_unique_seq` (unique): `tenant_id, anticipation_request_id, sequence`
- `index_anticipation_request_events_on_actor_party_id` (non-unique): `actor_party_id`
- `index_anticipation_request_events_on_anticipation_request_id` (non-unique): `anticipation_request_id`
- `index_anticipation_request_events_on_tenant_id` (non-unique): `tenant_id`

## `anticipation_requests`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `anticipation_requests_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `receivable_id` | `uuid` | false | `` | `receivables.id` |
| `receivable_allocation_id` | `uuid` | true | `` | `receivable_allocations.id` |
| `requester_party_id` | `uuid` | false | `` | `parties.id` |
| `idempotency_key` | `character varying` | false | `` | - |
| `requested_amount` | `numeric(18,2)` | false | `` | - |
| `discount_rate` | `numeric(12,8)` | false | `` | - |
| `discount_amount` | `numeric(18,2)` | false | `` | - |
| `net_amount` | `numeric(18,2)` | false | `` | - |
| `status` | `character varying` | false | `REQUESTED` | - |
| `channel` | `character varying` | false | `API` | - |
| `requested_at` | `timestamp(6) without time zone` | false | `` | - |
| `funded_at` | `timestamp(6) without time zone` | true | `` | - |
| `settled_at` | `timestamp(6) without time zone` | true | `` | - |
| `settlement_target_date` | `date` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `anticipation_requests_channel_check`: `channel::text = ANY (ARRAY['API'::character varying::text, 'PORTAL'::character varying::text, 'WEBHOOK'::character varying::text, 'INTERNAL'::character varying::text])`
- `anticipation_requests_discount_amount_check`: `discount_amount >= 0::numeric`
- `anticipation_requests_discount_rate_check`: `discount_rate >= 0::numeric`
- `anticipation_requests_net_amount_positive_check`: `net_amount > 0::numeric`
- `anticipation_requests_requested_amount_positive_check`: `requested_amount > 0::numeric`
- `anticipation_requests_status_check`: `status::text = ANY (ARRAY['REQUESTED'::character varying::text, 'APPROVED'::character varying::text, 'FUNDED'::character varying::text, 'SETTLED'::character varying::text, 'CANCELLED'::character varying::text, 'REJECTED'::character varying::text])`

### Indexes

- `index_anticipation_requests_on_receivable_allocation_id` (non-unique): `receivable_allocation_id`
- `index_anticipation_requests_on_receivable_id` (non-unique): `receivable_id`
- `index_anticipation_requests_on_requester_party_id` (non-unique): `requester_party_id`
- `index_anticipation_requests_on_tenant_id` (non-unique): `tenant_id`
- `index_anticipation_requests_on_tenant_id_and_idempotency_key` (unique): `tenant_id, idempotency_key`
- `index_anticipation_requests_on_tenant_receivable_status` (non-unique): `tenant_id, receivable_id, status`

## `anticipation_settlement_entries`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `anticipation_settlement_entries_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `receivable_payment_settlement_id` | `uuid` | false | `` | `receivable_payment_settlements.id` |
| `anticipation_request_id` | `uuid` | false | `` | `anticipation_requests.id` |
| `settled_amount` | `numeric(18,2)` | false | `` | - |
| `settled_at` | `timestamp(6) without time zone` | false | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `anticipation_settlement_entries_settled_positive_check`: `settled_amount > 0::numeric`

### Indexes

- `idx_ase_tenant_request_settled_at` (non-unique): `tenant_id, anticipation_request_id, settled_at`
- `idx_ase_unique_request_per_payment` (unique): `receivable_payment_settlement_id, anticipation_request_id`
- `idx_on_anticipation_request_id_a246566b52` (non-unique): `anticipation_request_id`
- `idx_on_receivable_payment_settlement_id_98a0387829` (non-unique): `receivable_payment_settlement_id`
- `index_anticipation_settlement_entries_on_tenant_id` (non-unique): `tenant_id`

## `api_access_tokens`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `api_access_tokens_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `user_id` | `bigint` | true | `` | `users.id` |
| `name` | `character varying` | false | `` | - |
| `token_identifier` | `character varying` | false | `` | - |
| `token_digest` | `character varying` | false | `` | - |
| `scopes` | `character varying` | false | `{}` | - |
| `expires_at` | `timestamp(6) without time zone` | true | `` | - |
| `revoked_at` | `timestamp(6) without time zone` | true | `` | - |
| `last_used_at` | `timestamp(6) without time zone` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `user_uuid_id` | `uuid` | true | `` | `users.uuid_id` |

### Check Constraints

- `api_access_tokens_token_digest_check`: `char_length(token_digest::text) > 0`
- `api_access_tokens_token_identifier_check`: `char_length(token_identifier::text) > 0`

### Indexes

- `index_api_access_tokens_on_tenant_id` (non-unique): `tenant_id`
- `index_api_access_tokens_on_tenant_lifecycle` (non-unique): `tenant_id, revoked_at, expires_at`
- `index_api_access_tokens_on_token_identifier` (unique): `token_identifier`
- `index_api_access_tokens_on_user_id` (non-unique): `user_id`
- `index_api_access_tokens_on_user_uuid_id` (non-unique): `user_uuid_id`

## `assignment_contracts`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `assignment_contracts_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `receivable_id` | `uuid` | false | `` | `receivables.id` |
| `anticipation_request_id` | `uuid` | true | `` | `anticipation_requests.id` |
| `assignor_party_id` | `uuid` | false | `` | `parties.id` |
| `assignee_party_id` | `uuid` | false | `` | `parties.id` |
| `contract_number` | `character varying` | false | `` | - |
| `status` | `character varying` | false | `DRAFT` | - |
| `currency` | `character varying(3)` | false | `BRL` | - |
| `assigned_amount` | `numeric(18,2)` | false | `` | - |
| `idempotency_key` | `character varying` | false | `` | - |
| `signed_at` | `timestamp(6) without time zone` | true | `` | - |
| `effective_at` | `timestamp(6) without time zone` | true | `` | - |
| `cancelled_at` | `timestamp(6) without time zone` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `assignment_contracts_assigned_amount_positive_check`: `assigned_amount > 0::numeric`
- `assignment_contracts_cancelled_at_required_check`: `status::text <> 'CANCELLED'::text OR cancelled_at IS NOT NULL`
- `assignment_contracts_cancelled_at_state_check`: `cancelled_at IS NULL OR status::text = 'CANCELLED'::text`
- `assignment_contracts_currency_brl_check`: `currency::text = 'BRL'::text`
- `assignment_contracts_idempotency_key_present_check`: `btrim(idempotency_key::text) <> ''::text`
- `assignment_contracts_signed_at_required_check`: `(status::text = ANY (ARRAY['DRAFT'::character varying::text, 'CANCELLED'::character varying::text])) OR signed_at IS NOT NULL`
- `assignment_contracts_status_check`: `status::text = ANY (ARRAY['DRAFT'::character varying::text, 'SIGNED'::character varying::text, 'ACTIVE'::character varying::text, 'SETTLED'::character varying::text, 'CANCELLED'::character varying::text])`

### Indexes

- `index_assignment_contracts_on_anticipation_request_id` (non-unique): `anticipation_request_id`
- `index_assignment_contracts_on_assignee_party_id` (non-unique): `assignee_party_id`
- `index_assignment_contracts_on_assignor_party_id` (non-unique): `assignor_party_id`
- `index_assignment_contracts_on_receivable_id` (non-unique): `receivable_id`
- `index_assignment_contracts_on_tenant_contract_number` (unique): `tenant_id, contract_number`
- `index_assignment_contracts_on_tenant_id` (non-unique): `tenant_id`
- `index_assignment_contracts_on_tenant_idempotency_key` (unique): `tenant_id, idempotency_key`
- `index_assignment_contracts_on_tenant_receivable` (non-unique): `tenant_id, receivable_id`

## `auth_challenges`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `auth_challenges_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `actor_party_id` | `uuid` | false | `` | `parties.id` |
| `purpose` | `character varying` | false | `` | - |
| `delivery_channel` | `character varying` | false | `` | - |
| `destination_masked` | `character varying` | false | `` | - |
| `code_digest` | `character varying` | false | `` | - |
| `status` | `character varying` | false | `PENDING` | - |
| `attempts` | `integer` | false | `0` | - |
| `max_attempts` | `integer` | false | `5` | - |
| `expires_at` | `timestamp(6) without time zone` | false | `` | - |
| `consumed_at` | `timestamp(6) without time zone` | true | `` | - |
| `request_id` | `character varying` | true | `` | - |
| `target_type` | `character varying` | false | `` | - |
| `target_id` | `uuid` | false | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `auth_challenges_attempts_check`: `attempts >= 0`
- `auth_challenges_delivery_channel_check`: `delivery_channel::text = ANY (ARRAY['EMAIL'::character varying::text, 'WHATSAPP'::character varying::text])`
- `auth_challenges_max_attempts_check`: `max_attempts > 0`
- `auth_challenges_status_check`: `status::text = ANY (ARRAY['PENDING'::character varying::text, 'VERIFIED'::character varying::text, 'EXPIRED'::character varying::text, 'CANCELLED'::character varying::text])`

### Indexes

- `index_auth_challenges_active_by_actor` (non-unique): `tenant_id, actor_party_id, status, expires_at`
- `index_auth_challenges_on_actor_party_id` (non-unique): `actor_party_id`
- `index_auth_challenges_on_tenant_id` (non-unique): `tenant_id`

## `document_events`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `document_events_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `document_id` | `uuid` | false | `` | `documents.id` |
| `receivable_id` | `uuid` | false | `` | `receivables.id` |
| `actor_party_id` | `uuid` | true | `` | `parties.id` |
| `event_type` | `character varying` | false | `` | - |
| `occurred_at` | `timestamp(6) without time zone` | false | `` | - |
| `request_id` | `character varying` | true | `` | - |
| `payload` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Indexes

- `index_document_events_on_actor_party_id` (non-unique): `actor_party_id`
- `index_document_events_on_document_id` (non-unique): `document_id`
- `index_document_events_on_receivable_id` (non-unique): `receivable_id`
- `index_document_events_on_tenant_document_occurred_at` (non-unique): `tenant_id, document_id, occurred_at`
- `index_document_events_on_tenant_id` (non-unique): `tenant_id`

## `documents`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `documents_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `receivable_id` | `uuid` | false | `` | `receivables.id` |
| `actor_party_id` | `uuid` | false | `` | `parties.id` |
| `document_type` | `character varying` | false | `` | - |
| `signature_method` | `character varying` | false | `OWN_PLATFORM_CONFIRMATION` | - |
| `status` | `character varying` | false | `SIGNED` | - |
| `sha256` | `character varying` | false | `` | - |
| `storage_key` | `character varying` | false | `` | - |
| `signed_at` | `timestamp(6) without time zone` | false | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `documents_status_check`: `status::text = ANY (ARRAY['SIGNED'::character varying::text, 'REVOKED'::character varying::text, 'SUPERSEDED'::character varying::text])`

### Indexes

- `index_documents_on_actor_party_id` (non-unique): `actor_party_id`
- `index_documents_on_receivable_id` (non-unique): `receivable_id`
- `index_documents_on_tenant_id` (non-unique): `tenant_id`
- `index_documents_on_tenant_id_and_sha256` (unique): `tenant_id, sha256`
- `index_documents_on_tenant_receivable` (non-unique): `tenant_id, receivable_id`

## `escrow_accounts`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `escrow_accounts_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `party_id` | `uuid` | false | `` | `parties.id` |
| `provider` | `character varying` | false | `` | - |
| `account_type` | `character varying` | false | `ESCROW` | - |
| `status` | `character varying` | false | `PENDING` | - |
| `provider_account_id` | `character varying` | true | `` | - |
| `provider_request_id` | `character varying` | true | `` | - |
| `last_synced_at` | `timestamp(6) without time zone` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `escrow_accounts_account_type_check`: `account_type::text = 'ESCROW'::text`
- `escrow_accounts_provider_check`: `provider::text = ANY (ARRAY['QITECH'::character varying, 'STARKBANK'::character varying]::text[])`
- `escrow_accounts_status_check`: `status::text = ANY (ARRAY['PENDING'::character varying, 'ACTIVE'::character varying, 'REJECTED'::character varying, 'FAILED'::character varying, 'CLOSED'::character varying]::text[])`

### Indexes

- `index_escrow_accounts_on_party_id` (non-unique): `party_id`
- `index_escrow_accounts_on_tenant_id` (non-unique): `tenant_id`
- `index_escrow_accounts_on_tenant_party_provider` (unique): `tenant_id, party_id, provider`
- `index_escrow_accounts_on_tenant_provider_account` (unique): `tenant_id, provider, provider_account_id` WHERE (provider_account_id IS NOT NULL)
- `index_escrow_accounts_on_tenant_status` (non-unique): `tenant_id, status`

## `escrow_payouts`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `escrow_payouts_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `anticipation_request_id` | `uuid` | true | `` | `anticipation_requests.id` |
| `party_id` | `uuid` | false | `` | `parties.id` |
| `escrow_account_id` | `uuid` | false | `` | `escrow_accounts.id` |
| `provider` | `character varying` | false | `` | - |
| `status` | `character varying` | false | `PENDING` | - |
| `amount` | `numeric(18,2)` | false | `` | - |
| `currency` | `character varying(3)` | false | `BRL` | - |
| `idempotency_key` | `character varying` | false | `` | - |
| `provider_transfer_id` | `character varying` | true | `` | - |
| `requested_at` | `timestamp(6) without time zone` | false | `` | - |
| `processed_at` | `timestamp(6) without time zone` | true | `` | - |
| `last_error_code` | `character varying` | true | `` | - |
| `last_error_message` | `character varying` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `receivable_payment_settlement_id` | `uuid` | true | `` | `receivable_payment_settlements.id` |

### Check Constraints

- `escrow_payouts_amount_positive_check`: `amount > 0::numeric`
- `escrow_payouts_currency_brl_check`: `currency::text = 'BRL'::text`
- `escrow_payouts_idempotency_key_present_check`: `btrim(idempotency_key::text) <> ''::text`
- `escrow_payouts_provider_check`: `provider::text = ANY (ARRAY['QITECH'::character varying, 'STARKBANK'::character varying]::text[])`
- `escrow_payouts_source_reference_check`: `anticipation_request_id IS NOT NULL OR receivable_payment_settlement_id IS NOT NULL`
- `escrow_payouts_status_check`: `status::text = ANY (ARRAY['PENDING'::character varying, 'SENT'::character varying, 'FAILED'::character varying]::text[])`

### Indexes

- `index_escrow_payouts_on_anticipation_request_id` (non-unique): `anticipation_request_id`
- `index_escrow_payouts_on_escrow_account_id` (non-unique): `escrow_account_id`
- `index_escrow_payouts_on_party_id` (non-unique): `party_id`
- `index_escrow_payouts_on_receivable_payment_settlement_id` (non-unique): `receivable_payment_settlement_id`
- `index_escrow_payouts_on_tenant_anticipation_party` (unique): `tenant_id, anticipation_request_id, party_id` WHERE (anticipation_request_id IS NOT NULL)
- `index_escrow_payouts_on_tenant_id` (non-unique): `tenant_id`
- `index_escrow_payouts_on_tenant_idempotency_key` (unique): `tenant_id, idempotency_key`
- `index_escrow_payouts_on_tenant_provider_transfer` (unique): `tenant_id, provider, provider_transfer_id` WHERE (provider_transfer_id IS NOT NULL)
- `index_escrow_payouts_on_tenant_settlement_party` (unique): `tenant_id, receivable_payment_settlement_id, party_id` WHERE (receivable_payment_settlement_id IS NOT NULL)
- `index_escrow_payouts_on_tenant_status_requested_at` (non-unique): `tenant_id, status, requested_at`

## `fdic_operations`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `fdic_operations_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `anticipation_request_id` | `uuid` | true | `` | `anticipation_requests.id` |
| `receivable_payment_settlement_id` | `uuid` | true | `` | `receivable_payment_settlements.id` |
| `provider` | `character varying` | false | `` | - |
| `operation_type` | `character varying` | false | `` | - |
| `status` | `character varying` | false | `PENDING` | - |
| `amount` | `numeric(18,2)` | false | `` | - |
| `currency` | `character varying` | false | `BRL` | - |
| `idempotency_key` | `character varying` | false | `` | - |
| `provider_reference` | `character varying` | true | `` | - |
| `requested_at` | `timestamp(6) without time zone` | false | `` | - |
| `processed_at` | `timestamp(6) without time zone` | true | `` | - |
| `last_error_code` | `character varying` | true | `` | - |
| `last_error_message` | `character varying` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `fdic_operations_amount_positive_check`: `amount > 0::numeric`
- `fdic_operations_currency_check`: `currency::text = 'BRL'::text`
- `fdic_operations_idempotency_key_present_check`: `btrim(idempotency_key::text) <> ''::text`
- `fdic_operations_operation_type_check`: `operation_type::text = ANY (ARRAY['FUNDING_REQUEST'::character varying, 'SETTLEMENT_REPORT'::character varying]::text[])`
- `fdic_operations_provider_check`: `provider::text = ANY (ARRAY['MOCK'::character varying, 'WEBHOOK'::character varying]::text[])`
- `fdic_operations_single_source_reference_check`: `anticipation_request_id IS NOT NULL AND receivable_payment_settlement_id IS NULL OR anticipation_request_id IS NULL AND receivable_payment_settlement_id IS NOT NULL`
- `fdic_operations_status_check`: `status::text = ANY (ARRAY['PENDING'::character varying, 'SENT'::character varying, 'FAILED'::character varying]::text[])`

### Indexes

- `index_fdic_operations_dispatch_scan` (non-unique): `tenant_id, operation_type, status, requested_at`
- `index_fdic_operations_on_anticipation_request_id` (non-unique): `anticipation_request_id`
- `index_fdic_operations_on_receivable_payment_settlement_id` (non-unique): `receivable_payment_settlement_id`
- `index_fdic_operations_on_tenant_id` (non-unique): `tenant_id`
- `index_fdic_operations_on_tenant_idempotency_key` (unique): `tenant_id, idempotency_key`
- `index_fdic_operations_unique_funding_per_request` (unique): `tenant_id, anticipation_request_id, operation_type` WHERE (anticipation_request_id IS NOT NULL)
- `index_fdic_operations_unique_settlement_per_payment` (unique): `tenant_id, receivable_payment_settlement_id, operation_type` WHERE (receivable_payment_settlement_id IS NOT NULL)

## `hospital_ownerships`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `hospital_ownerships_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `organization_party_id` | `uuid` | false | `` | `parties.id` |
| `hospital_party_id` | `uuid` | false | `` | `parties.id` |
| `active` | `boolean` | false | `true` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `hospital_ownerships_distinct_parties_check`: `organization_party_id <> hospital_party_id`

### Indexes

- `index_hospital_ownerships_on_hospital_party_id` (non-unique): `hospital_party_id`
- `index_hospital_ownerships_on_organization_party_id` (non-unique): `organization_party_id`
- `index_hospital_ownerships_on_tenant_active_hospital` (unique): `tenant_id, hospital_party_id` WHERE (active = true)
- `index_hospital_ownerships_on_tenant_id` (non-unique): `tenant_id`
- `index_hospital_ownerships_on_tenant_org_hospital` (unique): `tenant_id, organization_party_id, hospital_party_id`

## `kyc_documents`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `kyc_documents_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `kyc_profile_id` | `uuid` | false | `` | `kyc_profiles.id` |
| `party_id` | `uuid` | false | `` | `parties.id` |
| `document_type` | `character varying` | false | `` | - |
| `document_number` | `text` | true | `` | - |
| `issuing_country` | `character varying` | false | `BR` | - |
| `issuing_state` | `character varying(2)` | true | `` | - |
| `issued_on` | `date` | true | `` | - |
| `expires_on` | `date` | true | `` | - |
| `is_key_document` | `boolean` | false | `false` | - |
| `status` | `character varying` | false | `SUBMITTED` | - |
| `verified_at` | `timestamp(6) without time zone` | true | `` | - |
| `rejection_reason` | `character varying` | true | `` | - |
| `storage_key` | `character varying` | false | `` | - |
| `sha256` | `character varying` | false | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `kyc_documents_document_type_check`: `document_type::text = ANY (ARRAY['CPF'::character varying::text, 'CNPJ'::character varying::text, 'RG'::character varying::text, 'CNH'::character varying::text, 'PASSPORT'::character varying::text, 'PROOF_OF_ADDRESS'::character varying::text, 'SELFIE'::character varying::text, 'CONTRACT'::character varying::text, 'OTHER'::character varying::text])`
- `kyc_documents_issuing_state_check`: `issuing_state IS NULL OR (issuing_state::text = ANY (ARRAY['AC'::character varying::text, 'AL'::character varying::text, 'AP'::character varying::text, 'AM'::character varying::text, 'BA'::character varying::text, 'CE'::character varying::text, 'DF'::character varying::text, 'ES'::character varying::text, 'GO'::character varying::text, 'MA'::character varying::text, 'MT'::character varying::text, 'MS'::character varying::text, 'MG'::character varying::text, 'PA'::character varying::text, 'PB'::character varying::text, 'PR'::character varying::text, 'PE'::character varying::text, 'PI'::character varying::text, 'RJ'::character varying::text, 'RN'::character varying::text, 'RS'::character varying::text, 'RO'::character varying::text, 'RR'::character varying::text, 'SC'::character varying::text, 'SP'::character varying::text, 'SE'::character varying::text, 'TO'::character varying::text]))`
- `kyc_documents_key_document_type_check`: `NOT is_key_document OR (document_type::text = ANY (ARRAY['CPF'::character varying::text, 'CNPJ'::character varying::text]))`
- `kyc_documents_non_key_identity_docs_check`: `(document_type::text <> ALL (ARRAY['RG'::character varying::text, 'CNH'::character varying::text, 'PASSPORT'::character varying::text])) OR is_key_document = false`
- `kyc_documents_sha256_present_check`: `char_length(sha256::text) > 0`
- `kyc_documents_status_check`: `status::text = ANY (ARRAY['SUBMITTED'::character varying::text, 'VERIFIED'::character varying::text, 'REJECTED'::character varying::text, 'EXPIRED'::character varying::text])`
- `kyc_documents_storage_key_present_check`: `char_length(storage_key::text) > 0`

### Indexes

- `idx_kyc_documents_lookup` (non-unique): `tenant_id, party_id, document_type, status`
- `idx_kyc_documents_unique_key_per_type` (unique): `tenant_id, party_id, document_type` WHERE (is_key_document = true)
- `index_kyc_documents_on_kyc_profile_id` (non-unique): `kyc_profile_id`
- `index_kyc_documents_on_party_id` (non-unique): `party_id`
- `index_kyc_documents_on_tenant_id` (non-unique): `tenant_id`

## `kyc_events`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `kyc_events_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `kyc_profile_id` | `uuid` | false | `` | `kyc_profiles.id` |
| `party_id` | `uuid` | false | `` | `parties.id` |
| `actor_party_id` | `uuid` | true | `` | `parties.id` |
| `event_type` | `character varying` | false | `` | - |
| `occurred_at` | `timestamp(6) without time zone` | false | `` | - |
| `request_id` | `character varying` | true | `` | - |
| `payload` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Indexes

- `idx_kyc_events_tenant_party_time` (non-unique): `tenant_id, party_id, occurred_at`
- `idx_kyc_events_tenant_profile_time` (non-unique): `tenant_id, kyc_profile_id, occurred_at`
- `index_kyc_events_on_actor_party_id` (non-unique): `actor_party_id`
- `index_kyc_events_on_kyc_profile_id` (non-unique): `kyc_profile_id`
- `index_kyc_events_on_party_id` (non-unique): `party_id`
- `index_kyc_events_on_tenant_id` (non-unique): `tenant_id`

## `kyc_profiles`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `kyc_profiles_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `party_id` | `uuid` | false | `` | `parties.id` |
| `status` | `character varying` | false | `DRAFT` | - |
| `risk_level` | `character varying` | false | `UNKNOWN` | - |
| `submitted_at` | `timestamp(6) without time zone` | true | `` | - |
| `reviewed_at` | `timestamp(6) without time zone` | true | `` | - |
| `reviewer_party_id` | `uuid` | true | `` | `parties.id` |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `kyc_profiles_risk_level_check`: `risk_level::text = ANY (ARRAY['UNKNOWN'::character varying::text, 'LOW'::character varying::text, 'MEDIUM'::character varying::text, 'HIGH'::character varying::text])`
- `kyc_profiles_status_check`: `status::text = ANY (ARRAY['DRAFT'::character varying::text, 'PENDING_REVIEW'::character varying::text, 'NEEDS_INFORMATION'::character varying::text, 'APPROVED'::character varying::text, 'REJECTED'::character varying::text])`

### Indexes

- `index_kyc_profiles_on_party_id` (non-unique): `party_id`
- `index_kyc_profiles_on_reviewer_party_id` (non-unique): `reviewer_party_id`
- `index_kyc_profiles_on_tenant_id` (non-unique): `tenant_id`
- `index_kyc_profiles_on_tenant_party` (unique): `tenant_id, party_id`

## `ledger_entries`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `ledger_entries_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `txn_id` | `uuid` | false | `` | `ledger_transactions.txn_id` |
| `receivable_id` | `uuid` | true | `` | `receivables.id` |
| `account_code` | `character varying` | false | `` | - |
| `entry_side` | `character varying` | false | `` | - |
| `amount` | `numeric(18,2)` | false | `` | - |
| `currency` | `character varying(3)` | false | `BRL` | - |
| `party_id` | `uuid` | true | `` | `parties.id` |
| `source_type` | `character varying` | false | `` | - |
| `source_id` | `uuid` | false | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `posted_at` | `timestamp(6) without time zone` | false | `` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `entry_position` | `integer` | false | `` | - |
| `txn_entry_count` | `integer` | false | `` | - |
| `payment_reference` | `character varying` | true | `` | - |

### Check Constraints

- `ledger_entries_amount_positive_check`: `amount > 0::numeric`
- `ledger_entries_currency_brl_check`: `currency::text = 'BRL'::text`
- `ledger_entries_entry_position_lte_count_check`: `entry_position <= txn_entry_count`
- `ledger_entries_entry_position_positive_check`: `entry_position > 0`
- `ledger_entries_entry_side_check`: `entry_side::text = ANY (ARRAY['DEBIT'::character varying::text, 'CREDIT'::character varying::text])`
- `ledger_entries_settlement_payment_reference_required_check`: `source_type::text <> 'ReceivablePaymentSettlement'::text OR payment_reference IS NOT NULL AND btrim(payment_reference::text) <> ''::text`
- `ledger_entries_txn_entry_count_positive_check`: `txn_entry_count > 0`

### Indexes

- `idx_ledger_entries_tenant_account_posted` (non-unique): `tenant_id, account_code, posted_at`
- `idx_ledger_entries_tenant_payment_reference` (non-unique): `tenant_id, payment_reference` WHERE (payment_reference IS NOT NULL)
- `idx_ledger_entries_tenant_receivable_posted` (non-unique): `tenant_id, receivable_id, posted_at` WHERE (receivable_id IS NOT NULL)
- `idx_ledger_entries_tenant_source` (non-unique): `tenant_id, source_type, source_id`
- `idx_ledger_entries_tenant_txn` (non-unique): `tenant_id, txn_id`
- `idx_ledger_entries_tenant_txn_entry_position` (unique): `tenant_id, txn_id, entry_position`
- `index_ledger_entries_on_party_id` (non-unique): `party_id`
- `index_ledger_entries_on_receivable_id` (non-unique): `receivable_id`
- `index_ledger_entries_on_tenant_id` (non-unique): `tenant_id`

## `ledger_transactions`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `ledger_transactions_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `txn_id` | `uuid` | false | `` | - |
| `receivable_id` | `uuid` | true | `` | `receivables.id` |
| `source_type` | `character varying` | false | `` | - |
| `source_id` | `uuid` | false | `` | - |
| `payment_reference` | `character varying` | true | `` | - |
| `payload_hash` | `character varying` | false | `` | - |
| `entry_count` | `integer` | false | `` | - |
| `posted_at` | `timestamp(6) without time zone` | false | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `actor_party_id` | `uuid` | true | `` | `parties.id` |
| `actor_role` | `character varying` | true | `` | - |
| `request_id` | `character varying` | true | `` | - |

### Check Constraints

- `ledger_transactions_entry_count_positive_check`: `entry_count > 0`
- `ledger_transactions_payload_hash_present_check`: `btrim(payload_hash::text) <> ''::text`
- `ledger_transactions_settlement_payment_reference_required_check`: `source_type::text <> 'ReceivablePaymentSettlement'::text OR payment_reference IS NOT NULL AND btrim(payment_reference::text) <> ''::text`

### Indexes

- `idx_ledger_transactions_settlement_source_unique` (unique): `tenant_id, source_type, source_id` WHERE ((source_type)::text = 'ReceivablePaymentSettlement'::text)
- `idx_ledger_transactions_tenant_actor` (non-unique): `tenant_id, actor_party_id`
- `idx_ledger_transactions_tenant_payment_reference` (non-unique): `tenant_id, payment_reference` WHERE (payment_reference IS NOT NULL)
- `idx_ledger_transactions_tenant_source` (non-unique): `tenant_id, source_type, source_id`
- `idx_ledger_transactions_tenant_txn` (unique): `tenant_id, txn_id`
- `index_ledger_transactions_on_receivable_id` (non-unique): `receivable_id`
- `index_ledger_transactions_on_tenant_id` (non-unique): `tenant_id`

## `outbox_dispatch_attempts`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `outbox_dispatch_attempts_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `outbox_event_id` | `uuid` | false | `` | `outbox_events.id` |
| `attempt_number` | `integer` | false | `` | - |
| `status` | `character varying` | false | `` | - |
| `occurred_at` | `timestamp(6) without time zone` | false | `` | - |
| `next_attempt_at` | `timestamp(6) without time zone` | true | `` | - |
| `error_code` | `character varying` | true | `` | - |
| `error_message` | `character varying` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `outbox_dispatch_attempts_attempt_number_check`: `attempt_number > 0`
- `outbox_dispatch_attempts_status_check`: `status::text = ANY (ARRAY['SENT'::character varying, 'RETRY_SCHEDULED'::character varying, 'DEAD_LETTER'::character varying]::text[])`

### Indexes

- `index_outbox_dispatch_attempts_lookup` (non-unique): `tenant_id, outbox_event_id, occurred_at`
- `index_outbox_dispatch_attempts_on_outbox_event_id` (non-unique): `outbox_event_id`
- `index_outbox_dispatch_attempts_on_tenant_id` (non-unique): `tenant_id`
- `index_outbox_dispatch_attempts_retry_scan` (non-unique): `tenant_id, status, next_attempt_at`
- `index_outbox_dispatch_attempts_unique_attempt` (unique): `tenant_id, outbox_event_id, attempt_number`

## `outbox_events`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `outbox_events_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `aggregate_type` | `character varying` | false | `` | - |
| `aggregate_id` | `uuid` | false | `` | - |
| `event_type` | `character varying` | false | `` | - |
| `status` | `character varying` | false | `PENDING` | - |
| `attempts` | `integer` | false | `0` | - |
| `next_attempt_at` | `timestamp(6) without time zone` | true | `` | - |
| `sent_at` | `timestamp(6) without time zone` | true | `` | - |
| `idempotency_key` | `character varying` | true | `` | - |
| `payload` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `outbox_events_status_check`: `status::text = ANY (ARRAY['PENDING'::character varying::text, 'SENT'::character varying::text, 'FAILED'::character varying::text, 'CANCELLED'::character varying::text])`

### Indexes

- `index_outbox_events_on_tenant_id` (non-unique): `tenant_id`
- `index_outbox_events_on_tenant_idempotency_key` (unique): `tenant_id, idempotency_key` WHERE (idempotency_key IS NOT NULL)
- `index_outbox_events_pending_scan` (non-unique): `tenant_id, status, created_at`

## `parties`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `parties_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `kind` | `character varying` | false | `` | - |
| `external_ref` | `character varying` | true | `` | - |
| `document_number` | `text` | true | `` | - |
| `legal_name` | `text` | false | `` | - |
| `display_name` | `text` | true | `` | - |
| `active` | `boolean` | false | `true` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `document_type` | `character varying` | false | `` | - |

### Check Constraints

- `parties_document_type_check`: `document_type::text = ANY (ARRAY['CPF'::character varying::text, 'CNPJ'::character varying::text])`
- `parties_document_type_kind_check`: `kind::text = 'PHYSICIAN_PF'::text AND document_type::text = 'CPF'::text OR kind::text <> 'PHYSICIAN_PF'::text AND document_type::text = 'CNPJ'::text`
- `parties_kind_check`: `kind::text = ANY (ARRAY['HOSPITAL'::character varying::text, 'SUPPLIER'::character varying::text, 'PHYSICIAN_PF'::character varying::text, 'LEGAL_ENTITY_PJ'::character varying::text, 'FIDC'::character varying::text, 'PLATFORM'::character varying::text])`

### Indexes

- `index_parties_on_tenant_id` (non-unique): `tenant_id`
- `index_parties_on_tenant_kind_document` (unique): `tenant_id, kind, document_number` WHERE (document_number IS NOT NULL)
- `index_parties_on_tenant_kind_external_ref` (unique): `tenant_id, kind, external_ref` WHERE (external_ref IS NOT NULL)

## `partner_applications`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `partner_applications_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `created_by_user_id` | `bigint` | true | `` | `users.id` |
| `name` | `character varying` | false | `` | - |
| `client_id` | `character varying` | false | `` | - |
| `client_secret_digest` | `character varying` | false | `` | - |
| `scopes` | `text` | false | `{}` | - |
| `token_ttl_minutes` | `integer` | false | `15` | - |
| `allowed_origins` | `text` | false | `{}` | - |
| `active` | `boolean` | false | `true` | - |
| `last_used_at` | `timestamp(6) without time zone` | true | `` | - |
| `rotated_at` | `timestamp(6) without time zone` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `created_by_user_uuid_id` | `uuid` | true | `` | `users.uuid_id` |

### Check Constraints

- `partner_applications_client_id_present_check`: `btrim(client_id::text) <> ''::text`
- `partner_applications_client_secret_digest_present_check`: `btrim(client_secret_digest::text) <> ''::text`
- `partner_applications_name_present_check`: `btrim(name::text) <> ''::text`
- `partner_applications_token_ttl_range_check`: `token_ttl_minutes >= 5 AND token_ttl_minutes <= 60`

### Indexes

- `index_partner_applications_on_client_id` (unique): `client_id`
- `index_partner_applications_on_created_by_user_id` (non-unique): `created_by_user_id`
- `index_partner_applications_on_created_by_user_uuid_id` (non-unique): `created_by_user_uuid_id`
- `index_partner_applications_on_tenant_id` (non-unique): `tenant_id`
- `index_partner_applications_tenant_active_created` (non-unique): `tenant_id, active, created_at`

## `physician_anticipation_authorizations`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `physician_anticipation_authorizations_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `legal_entity_party_id` | `uuid` | false | `` | `parties.id` |
| `granted_by_membership_id` | `uuid` | false | `` | `physician_legal_entity_memberships.id` |
| `beneficiary_physician_party_id` | `uuid` | false | `` | `parties.id` |
| `status` | `character varying` | false | `ACTIVE` | - |
| `valid_from` | `timestamp(6) without time zone` | false | `` | - |
| `valid_until` | `timestamp(6) without time zone` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `physician_authorization_status_check`: `status::text = ANY (ARRAY['ACTIVE'::character varying::text, 'REVOKED'::character varying::text, 'EXPIRED'::character varying::text])`

### Indexes

- `idx_on_beneficiary_physician_party_id_49cb368edd` (non-unique): `beneficiary_physician_party_id`
- `idx_on_granted_by_membership_id_ba97263f49` (non-unique): `granted_by_membership_id`
- `idx_on_legal_entity_party_id_67e9dbdf42` (non-unique): `legal_entity_party_id`
- `index_active_physician_authorizations` (non-unique): `tenant_id, legal_entity_party_id, beneficiary_physician_party_id` WHERE ((status)::text = 'ACTIVE'::text)
- `index_physician_anticipation_authorizations_on_tenant_id` (non-unique): `tenant_id`

## `physician_cnpj_split_policies`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `physician_cnpj_split_policies_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `legal_entity_party_id` | `uuid` | false | `` | `parties.id` |
| `scope` | `character varying` | false | `SHARED_CNPJ` | - |
| `cnpj_share_rate` | `numeric(12,8)` | false | `0.3` | - |
| `physician_share_rate` | `numeric(12,8)` | false | `0.7` | - |
| `status` | `character varying` | false | `ACTIVE` | - |
| `effective_from` | `timestamp(6) without time zone` | false | `` | - |
| `effective_until` | `timestamp(6) without time zone` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `physician_cnpj_split_policies_cnpj_rate_check`: `cnpj_share_rate >= 0::numeric AND cnpj_share_rate <= 1::numeric`
- `physician_cnpj_split_policies_physician_rate_check`: `physician_share_rate >= 0::numeric AND physician_share_rate <= 1::numeric`
- `physician_cnpj_split_policies_scope_check`: `scope::text = 'SHARED_CNPJ'::text`
- `physician_cnpj_split_policies_status_check`: `status::text = ANY (ARRAY['ACTIVE'::character varying::text, 'INACTIVE'::character varying::text])`
- `physician_cnpj_split_policies_total_rate_check`: `(cnpj_share_rate + physician_share_rate) = 1.00000000`

### Indexes

- `index_physician_cnpj_split_policies_active_unique` (unique): `tenant_id, legal_entity_party_id, scope, status` WHERE ((status)::text = 'ACTIVE'::text)
- `index_physician_cnpj_split_policies_lookup` (non-unique): `tenant_id, legal_entity_party_id, scope, effective_from`
- `index_physician_cnpj_split_policies_on_legal_entity_party_id` (non-unique): `legal_entity_party_id`
- `index_physician_cnpj_split_policies_on_tenant_id` (non-unique): `tenant_id`

## `physician_legal_entity_memberships`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `physician_legal_entity_memberships_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `physician_party_id` | `uuid` | false | `` | `parties.id` |
| `legal_entity_party_id` | `uuid` | false | `` | `parties.id` |
| `membership_role` | `character varying` | false | `` | - |
| `status` | `character varying` | false | `ACTIVE` | - |
| `joined_at` | `timestamp(6) without time zone` | false | `` | - |
| `left_at` | `timestamp(6) without time zone` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `physician_membership_role_check`: `membership_role::text = ANY (ARRAY['ADMIN'::character varying::text, 'MEMBER'::character varying::text])`
- `physician_membership_status_check`: `status::text = ANY (ARRAY['ACTIVE'::character varying::text, 'INACTIVE'::character varying::text])`

### Indexes

- `idx_on_legal_entity_party_id_0544188f89` (non-unique): `legal_entity_party_id`
- `index_physician_legal_entity_memberships_on_physician_party_id` (non-unique): `physician_party_id`
- `index_physician_legal_entity_memberships_on_tenant_id` (non-unique): `tenant_id`
- `index_physician_memberships_unique` (unique): `tenant_id, physician_party_id, legal_entity_party_id`

## `physicians`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `physicians_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `party_id` | `uuid` | false | `` | `parties.id` |
| `full_name` | `text` | false | `` | - |
| `email` | `text` | true | `` | - |
| `phone` | `text` | true | `` | - |
| `active` | `boolean` | false | `true` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `crm_number` | `character varying` | true | `` | - |
| `crm_state` | `character varying(2)` | true | `` | - |

### Check Constraints

- `physicians_crm_number_length_check`: `crm_number IS NULL OR char_length(crm_number::text) >= 4 AND char_length(crm_number::text) <= 10`
- `physicians_crm_pair_presence_check`: `crm_number IS NULL AND crm_state IS NULL OR crm_number IS NOT NULL AND crm_state IS NOT NULL`
- `physicians_crm_state_check`: `crm_state IS NULL OR (crm_state::text = ANY (ARRAY['AC'::character varying::text, 'AL'::character varying::text, 'AP'::character varying::text, 'AM'::character varying::text, 'BA'::character varying::text, 'CE'::character varying::text, 'DF'::character varying::text, 'ES'::character varying::text, 'GO'::character varying::text, 'MA'::character varying::text, 'MT'::character varying::text, 'MS'::character varying::text, 'MG'::character varying::text, 'PA'::character varying::text, 'PB'::character varying::text, 'PR'::character varying::text, 'PE'::character varying::text, 'PI'::character varying::text, 'RJ'::character varying::text, 'RN'::character varying::text, 'RS'::character varying::text, 'RO'::character varying::text, 'RR'::character varying::text, 'SC'::character varying::text, 'SP'::character varying::text, 'SE'::character varying::text, 'TO'::character varying::text]))`

### Indexes

- `idx_physicians_tenant_crm` (unique): `tenant_id, crm_state, crm_number` WHERE (crm_number IS NOT NULL)
- `index_physicians_on_party_id` (non-unique): `party_id`
- `index_physicians_on_tenant_id` (non-unique): `tenant_id`
- `index_physicians_on_tenant_id_and_party_id` (unique): `tenant_id, party_id`

## `provider_webhook_receipts`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `provider_webhook_receipts_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `provider` | `character varying` | false | `` | - |
| `provider_event_id` | `character varying` | false | `` | - |
| `event_type` | `character varying` | true | `` | - |
| `signature` | `character varying` | true | `` | - |
| `payload_sha256` | `character varying` | false | `` | - |
| `payload` | `jsonb` | false | `{}` | - |
| `request_headers` | `jsonb` | false | `{}` | - |
| `status` | `character varying` | false | `` | - |
| `error_code` | `character varying` | true | `` | - |
| `error_message` | `character varying` | true | `` | - |
| `processed_at` | `timestamp(6) without time zone` | false | `` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `provider_webhook_receipts_event_id_present_check`: `btrim(provider_event_id::text) <> ''::text`
- `provider_webhook_receipts_payload_sha256_check`: `payload_sha256::text ~ '^[0-9a-f]{64}$'::text`
- `provider_webhook_receipts_provider_check`: `provider::text = ANY (ARRAY['QITECH'::character varying, 'STARKBANK'::character varying]::text[])`
- `provider_webhook_receipts_status_check`: `status::text = ANY (ARRAY['PROCESSED'::character varying, 'IGNORED'::character varying, 'FAILED'::character varying]::text[])`

### Indexes

- `index_provider_webhook_receipts_lookup` (non-unique): `tenant_id, provider, status, processed_at`
- `index_provider_webhook_receipts_on_tenant_id` (non-unique): `tenant_id`
- `index_provider_webhook_receipts_unique_event` (unique): `tenant_id, provider, provider_event_id`

## `receivable_allocations`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `receivable_allocations_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `receivable_id` | `uuid` | false | `` | `receivables.id` |
| `sequence` | `integer` | false | `` | - |
| `allocated_party_id` | `uuid` | false | `` | `parties.id` |
| `physician_party_id` | `uuid` | true | `` | `parties.id` |
| `gross_amount` | `numeric(18,2)` | false | `` | - |
| `tax_reserve_amount` | `numeric(18,2)` | false | `0.0` | - |
| `eligible_for_anticipation` | `boolean` | false | `true` | - |
| `status` | `character varying` | false | `OPEN` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `receivable_allocations_gross_amount_check`: `gross_amount >= 0::numeric`
- `receivable_allocations_status_check`: `status::text = ANY (ARRAY['OPEN'::character varying::text, 'SETTLED'::character varying::text, 'CANCELLED'::character varying::text])`
- `receivable_allocations_tax_reserve_amount_check`: `tax_reserve_amount >= 0::numeric`

### Indexes

- `index_receivable_allocations_on_allocated_party_id` (non-unique): `allocated_party_id`
- `index_receivable_allocations_on_physician_party_id` (non-unique): `physician_party_id`
- `index_receivable_allocations_on_receivable_id` (non-unique): `receivable_id`
- `index_receivable_allocations_on_receivable_id_and_sequence` (unique): `receivable_id, sequence`
- `index_receivable_allocations_on_tenant_allocated_party` (non-unique): `tenant_id, allocated_party_id`
- `index_receivable_allocations_on_tenant_id` (non-unique): `tenant_id`

## `receivable_events`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `receivable_events_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `receivable_id` | `uuid` | false | `` | `receivables.id` |
| `sequence` | `bigint` | false | `` | - |
| `event_type` | `character varying` | false | `` | - |
| `actor_party_id` | `uuid` | true | `` | `parties.id` |
| `actor_role` | `character varying` | true | `` | - |
| `occurred_at` | `timestamp(6) without time zone` | false | `` | - |
| `request_id` | `character varying` | true | `` | - |
| `prev_hash` | `character varying` | true | `` | - |
| `event_hash` | `character varying` | false | `` | - |
| `payload` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Indexes

- `index_receivable_events_on_actor_party_id` (non-unique): `actor_party_id`
- `index_receivable_events_on_event_hash` (unique): `event_hash`
- `index_receivable_events_on_receivable_id` (non-unique): `receivable_id`
- `index_receivable_events_on_receivable_id_and_sequence` (unique): `receivable_id, sequence`
- `index_receivable_events_on_tenant_id` (non-unique): `tenant_id`
- `index_receivable_events_on_tenant_occurred_at` (non-unique): `tenant_id, occurred_at`

## `receivable_kinds`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `receivable_kinds_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | true | `` | `tenants.id` |
| `code` | `character varying` | false | `` | - |
| `name` | `character varying` | false | `` | - |
| `source_family` | `character varying` | false | `` | - |
| `active` | `boolean` | false | `true` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `receivable_kinds_source_family_check`: `source_family::text = ANY (ARRAY['PHYSICIAN'::character varying::text, 'SUPPLIER'::character varying::text, 'OTHER'::character varying::text])`

### Indexes

- `index_receivable_kinds_on_tenant_and_code` (unique): `tenant_id, code`
- `index_receivable_kinds_on_tenant_id` (non-unique): `tenant_id`

## `receivable_payment_settlements`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `true`

- Policies:
  - `receivable_payment_settlements_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `receivable_id` | `uuid` | false | `` | `receivables.id` |
| `receivable_allocation_id` | `uuid` | true | `` | `receivable_allocations.id` |
| `paid_amount` | `numeric(18,2)` | false | `` | - |
| `cnpj_amount` | `numeric(18,2)` | false | `0.0` | - |
| `fdic_amount` | `numeric(18,2)` | false | `0.0` | - |
| `beneficiary_amount` | `numeric(18,2)` | false | `0.0` | - |
| `fdic_balance_before` | `numeric(18,2)` | false | `0.0` | - |
| `fdic_balance_after` | `numeric(18,2)` | false | `0.0` | - |
| `paid_at` | `timestamp(6) without time zone` | false | `` | - |
| `payment_reference` | `character varying` | false | `` | - |
| `request_id` | `character varying` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `idempotency_key` | `character varying` | false | `` | - |

### Check Constraints

- `receivable_payment_settlements_beneficiary_non_negative_check`: `beneficiary_amount >= 0::numeric`
- `receivable_payment_settlements_cnpj_non_negative_check`: `cnpj_amount >= 0::numeric`
- `receivable_payment_settlements_fdic_after_non_negative_check`: `fdic_balance_after >= 0::numeric`
- `receivable_payment_settlements_fdic_balance_flow_check`: `fdic_balance_before >= fdic_balance_after`
- `receivable_payment_settlements_fdic_before_non_negative_check`: `fdic_balance_before >= 0::numeric`
- `receivable_payment_settlements_fdic_non_negative_check`: `fdic_amount >= 0::numeric`
- `receivable_payment_settlements_idempotency_key_present_check`: `btrim(idempotency_key::text) <> ''::text`
- `receivable_payment_settlements_paid_positive_check`: `paid_amount > 0::numeric`
- `receivable_payment_settlements_payment_reference_present_check`: `btrim(payment_reference::text) <> ''::text`
- `receivable_payment_settlements_split_total_check`: `(cnpj_amount + fdic_amount + beneficiary_amount) = paid_amount`

### Indexes

- `idx_on_receivable_allocation_id_cc033624f4` (non-unique): `receivable_allocation_id`
- `idx_rps_tenant_idempotency_key` (unique): `tenant_id, idempotency_key`
- `idx_rps_tenant_payment_ref` (unique): `tenant_id, payment_reference`
- `idx_rps_tenant_receivable_paid_at` (non-unique): `tenant_id, receivable_id, paid_at`
- `index_receivable_payment_settlements_on_receivable_id` (non-unique): `receivable_id`
- `index_receivable_payment_settlements_on_tenant_id` (non-unique): `tenant_id`

## `receivable_statistics_daily`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `receivable_statistics_daily_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `stat_date` | `date` | false | `` | - |
| `receivable_kind_id` | `uuid` | false | `` | `receivable_kinds.id` |
| `metric_scope` | `character varying` | false | `` | - |
| `scope_party_id` | `uuid` | true | `` | `parties.id` |
| `receivable_count` | `bigint` | false | `0` | - |
| `gross_amount` | `numeric(18,2)` | false | `0.0` | - |
| `anticipated_count` | `bigint` | false | `0` | - |
| `anticipated_amount` | `numeric(18,2)` | false | `0.0` | - |
| `settled_count` | `bigint` | false | `0` | - |
| `settled_amount` | `numeric(18,2)` | false | `0.0` | - |
| `last_computed_at` | `timestamp(6) without time zone` | false | `` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `receivable_statistics_daily_metric_scope_check`: `metric_scope::text = ANY (ARRAY['GLOBAL'::character varying::text, 'DEBTOR'::character varying::text, 'CREDITOR'::character varying::text, 'BENEFICIARY'::character varying::text])`

### Indexes

- `index_receivable_statistics_daily_on_receivable_kind_id` (non-unique): `receivable_kind_id`
- `index_receivable_statistics_daily_on_scope_party_id` (non-unique): `scope_party_id`
- `index_receivable_statistics_daily_on_tenant_id` (non-unique): `tenant_id`
- `index_receivable_statistics_daily_unique_dimension` (unique): `tenant_id, stat_date, receivable_kind_id, metric_scope, scope_party_id`

## `receivables`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `receivables_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `receivable_kind_id` | `uuid` | false | `` | `receivable_kinds.id` |
| `debtor_party_id` | `uuid` | false | `` | `parties.id` |
| `creditor_party_id` | `uuid` | false | `` | `parties.id` |
| `beneficiary_party_id` | `uuid` | false | `` | `parties.id` |
| `contract_reference` | `character varying` | true | `` | - |
| `external_reference` | `character varying` | true | `` | - |
| `gross_amount` | `numeric(18,2)` | false | `` | - |
| `currency` | `character varying(3)` | false | `BRL` | - |
| `performed_at` | `timestamp(6) without time zone` | false | `` | - |
| `due_at` | `timestamp(6) without time zone` | false | `` | - |
| `cutoff_at` | `timestamp(6) without time zone` | false | `` | - |
| `status` | `character varying` | false | `PERFORMED` | - |
| `active` | `boolean` | false | `true` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `receivables_currency_brl_check`: `currency::text = 'BRL'::text`
- `receivables_gross_amount_positive_check`: `gross_amount > 0::numeric`
- `receivables_status_check`: `status::text = ANY (ARRAY['PERFORMED'::character varying::text, 'ANTICIPATION_REQUESTED'::character varying::text, 'FUNDED'::character varying::text, 'SETTLED'::character varying::text, 'CANCELLED'::character varying::text])`

### Indexes

- `index_receivables_on_beneficiary_party_id` (non-unique): `beneficiary_party_id`
- `index_receivables_on_creditor_party_id` (non-unique): `creditor_party_id`
- `index_receivables_on_debtor_party_id` (non-unique): `debtor_party_id`
- `index_receivables_on_receivable_kind_id` (non-unique): `receivable_kind_id`
- `index_receivables_on_tenant_external_reference` (unique): `tenant_id, external_reference` WHERE (external_reference IS NOT NULL)
- `index_receivables_on_tenant_id` (non-unique): `tenant_id`
- `index_receivables_on_tenant_status_due_at` (non-unique): `tenant_id, status, due_at`

## `reconciliation_exceptions`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `reconciliation_exceptions_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `resolved_by_party_id` | `uuid` | true | `` | `parties.id` |
| `source` | `character varying` | false | `` | - |
| `provider` | `character varying` | false | `` | - |
| `external_event_id` | `character varying` | false | `` | - |
| `code` | `character varying` | false | `` | - |
| `message` | `character varying` | false | `` | - |
| `payload_sha256` | `character varying` | true | `` | - |
| `payload` | `jsonb` | false | `{}` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `status` | `character varying` | false | `OPEN` | - |
| `occurrences_count` | `integer` | false | `1` | - |
| `first_seen_at` | `timestamp(6) without time zone` | false | `` | - |
| `last_seen_at` | `timestamp(6) without time zone` | false | `` | - |
| `resolved_at` | `timestamp(6) without time zone` | true | `` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `reconciliation_exceptions_code_present_check`: `btrim(code::text) <> ''::text`
- `reconciliation_exceptions_external_event_id_present_check`: `btrim(external_event_id::text) <> ''::text`
- `reconciliation_exceptions_message_present_check`: `btrim(message::text) <> ''::text`
- `reconciliation_exceptions_occurrences_count_positive_check`: `occurrences_count > 0`
- `reconciliation_exceptions_payload_sha256_check`: `payload_sha256 IS NULL OR payload_sha256::text ~ '^[0-9a-f]{64}$'::text`
- `reconciliation_exceptions_provider_check`: `provider::text = ANY (ARRAY['QITECH'::character varying, 'STARKBANK'::character varying]::text[])`
- `reconciliation_exceptions_source_check`: `source::text = 'ESCROW_WEBHOOK'::text`
- `reconciliation_exceptions_status_check`: `status::text = ANY (ARRAY['OPEN'::character varying, 'RESOLVED'::character varying]::text[])`

### Indexes

- `index_reconciliation_exceptions_on_resolved_by_party_id` (non-unique): `resolved_by_party_id`
- `index_reconciliation_exceptions_on_tenant_id` (non-unique): `tenant_id`
- `index_reconciliation_exceptions_open_lookup` (non-unique): `tenant_id, status, last_seen_at`
- `index_reconciliation_exceptions_unique_signature` (unique): `tenant_id, source, provider, external_event_id, code`

## `roles`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `roles_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `code` | `character varying` | false | `` | - |
| `name` | `character varying` | false | `` | - |
| `active` | `boolean` | false | `true` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `roles_code_check`: `code::text = ANY (ARRAY['hospital_admin'::character varying::text, 'supplier_user'::character varying::text, 'ops_admin'::character varying::text, 'physician_pf_user'::character varying::text, 'physician_pj_admin'::character varying::text, 'physician_pj_member'::character varying::text, 'integration_api'::character varying::text])`

### Indexes

- `index_roles_on_tenant_id` (non-unique): `tenant_id`
- `index_roles_on_tenant_id_and_code` (unique): `tenant_id, code`

## `sessions`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `sessions_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `bigint` | false | `` | - |
| `user_id` | `bigint` | false | `` | `users.id` |
| `ip_address` | `character varying` | true | `` | - |
| `user_agent` | `character varying` | true | `` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `admin_webauthn_verified_at` | `timestamp(6) without time zone` | true | `` | - |
| `user_uuid_id` | `uuid` | true | `` | `users.uuid_id` |

### Indexes

- `index_sessions_on_tenant_id` (non-unique): `tenant_id`
- `index_sessions_on_tenant_id_and_user_id` (non-unique): `tenant_id, user_id`
- `index_sessions_on_user_id` (non-unique): `user_id`
- `index_sessions_on_user_uuid_id` (non-unique): `user_uuid_id`

## `tenants`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `tenants_ops_admin_policy`
  - `tenants_self_policy`
  - `tenants_slug_lookup_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `slug` | `citext` | false | `` | - |
| `name` | `character varying` | false | `` | - |
| `active` | `boolean` | false | `true` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Indexes

- `index_tenants_on_slug` (unique): `slug`

## `user_roles`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `user_roles_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `user_id` | `bigint` | false | `` | `users.id` |
| `role_id` | `uuid` | false | `` | `roles.id` |
| `assigned_by_user_id` | `bigint` | true | `` | `users.id` |
| `assigned_at` | `timestamp(6) without time zone` | false | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Indexes

- `index_user_roles_on_assigned_by_user_id` (non-unique): `assigned_by_user_id`
- `index_user_roles_on_role_id` (non-unique): `role_id`
- `index_user_roles_on_tenant_id` (non-unique): `tenant_id`
- `index_user_roles_on_tenant_role` (non-unique): `tenant_id, role_id`
- `index_user_roles_on_tenant_user` (unique): `tenant_id, user_id`
- `index_user_roles_on_user_id` (non-unique): `user_id`

## `users`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `users_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `bigint` | false | `` | - |
| `email_address` | `text` | false | `` | - |
| `password_digest` | `character varying` | false | `` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `party_id` | `uuid` | true | `` | `parties.id` |
| `mfa_enabled` | `boolean` | false | `false` | - |
| `mfa_secret` | `character varying` | true | `` | - |
| `mfa_last_otp_at` | `timestamp(6) without time zone` | true | `` | - |
| `webauthn_id` | `character varying` | true | `` | - |
| `uuid_id` | `uuid` | false | `` | - |

### Indexes

- `index_users_on_email_address` (unique): `email_address`
- `index_users_on_party_id` (non-unique): `party_id`
- `index_users_on_tenant_id` (non-unique): `tenant_id`
- `index_users_on_tenant_id_and_webauthn_id` (unique): `tenant_id, webauthn_id` WHERE (webauthn_id IS NOT NULL)
- `index_users_on_uuid_id` (unique): `uuid_id`

## `webauthn_credentials`

- Primary key: `id`
- RLS enabled: `true`
- RLS forced: `true`
- Append-only guard: `false`

- Policies:
  - `webauthn_credentials_tenant_policy`

### Columns

| Column | SQL Type | Null | Default | FK |
| --- | --- | --- | --- | --- |
| `id` | `uuid` | false | `` | - |
| `tenant_id` | `uuid` | false | `` | `tenants.id` |
| `user_id` | `bigint` | false | `` | `users.id` |
| `webauthn_id` | `character varying` | false | `` | - |
| `public_key` | `text` | false | `` | - |
| `sign_count` | `bigint` | false | `0` | - |
| `nickname` | `character varying` | true | `` | - |
| `last_used_at` | `timestamp(6) without time zone` | true | `` | - |
| `metadata` | `jsonb` | false | `{}` | - |
| `created_at` | `timestamp(6) without time zone` | false | `` | - |
| `updated_at` | `timestamp(6) without time zone` | false | `` | - |

### Check Constraints

- `webauthn_credentials_sign_count_non_negative_check`: `sign_count >= 0`

### Indexes

- `index_webauthn_credentials_on_tenant_credential` (unique): `tenant_id, webauthn_id`
- `index_webauthn_credentials_on_tenant_id` (non-unique): `tenant_id`
- `index_webauthn_credentials_on_tenant_user_credential` (unique): `tenant_id, user_id, webauthn_id`
- `index_webauthn_credentials_on_user_id` (non-unique): `user_id`
