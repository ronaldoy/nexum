# Nexum Capital App

Rails application for receivables anticipation platform.

For full architecture, domain flow, and demo walkthrough see root `README.md`.

## Stack
- Rails 8.2 edge (tracking Rails main branch pre-stable)
- PostgreSQL 18.1
- Solid Queue / Solid Cache / Solid Cable
- Hotwire (`turbo-rails`, `stimulus-rails`)

## Local Setup
1. Start PostgreSQL 18.1 from repository root:
   - `./bin/db-up`
2. Ensure local databases exist:
   - `./bin/db-bootstrap`
3. Install gems:
   - `cd app && rv clean-install`
4. Run migrations:
   - `cd app && rv ruby run -- -S bin/rails db:migrate`
5. Start app:
   - `cd app && rv ruby run -- -S bin/rails server`

## Key Architecture Rules
- Financial amounts/rates:
  - `BigDecimal` in Ruby
  - `NUMERIC` in PostgreSQL
  - string values in API payloads
- Idempotency is mandatory for all write operations.
- Append-only audit/event tables are enforced by DB triggers.
- PostgreSQL RLS (`tenant_id`) enforced via session context.
- Business timezone: `America/Sao_Paulo`.
- Cutoff: `23:59:59` local time; payment target next business day.
- User authentication:
  - `has_secure_password` with `Argon2`
  - Rails native sessions for web
  - first-party bearer tokens for integration APIs

## API Bootstrap
- `GET /health` liveness check.
- `GET /ready` readiness check (database connectivity).
- `GET /admin/dashboard` global web admin dashboard (`ops_admin` only).
- `GET /api/v1/receivables` list receivables scoped by tenant context.
- `GET /api/v1/hospital_organizations` list organizations and managed hospitals.
- `GET /api/v1/receivables/:id` fetch single receivable.
- `GET /api/v1/receivables/:id/history` full append-only timeline (events + document events).
- `GET /docs/openapi/v1` serves OpenAPI v1 contract.
- `POST /webhooks/escrow/:provider/:tenant_slug` receives signed provider webhooks and reconciles escrow payout/account status.
- `GET /admin/api_access_tokens` lists integration tokens for the selected tenant (`ops_admin` + passkey step-up).
- `POST /admin/api_access_tokens` issues a new integration token (`ops_admin` + passkey step-up).
- `DELETE /admin/api_access_tokens/:id` revokes an integration token (`ops_admin` + passkey step-up).
- OpenAPI source file: `../docs/openapi/v1.yaml`.
- Generated API reference: `../docs/api_reference.md`.
- Generated DB model docs: `../docs/database_model.md`.

## Escrow Integrations (QI Tech / StarkBank-ready)
- Provider abstraction: `Integrations::Escrow`.
- Event trigger: `RECEIVABLE_ESCROW_EXCESS_PAYOUT_REQUESTED` after receivable settlement computes positive `beneficiary_amount` (excess).
- Outbox routing: `Outbox::EventRouter` -> `Integrations::Escrow::DispatchPayout`.
- Persisted state:
  - `escrow_accounts`
  - `escrow_payouts`
  - `provider_webhook_receipts`
  - `reconciliation_exceptions`
- Destination account guardrail:
  - EXCESS payout destination `taxpayer_id` must match recipient party CPF/CNPJ.

### Provider configuration
- `ESCROW_DEFAULT_PROVIDER` (`QITECH` in v1)
- `ESCROW_ENABLE_STARKBANK` (`false` by default; set `true` only when StarkBank rollout is enabled)
- QI Tech:
  - `QITECH_BASE_URL`
  - `QITECH_API_CLIENT_KEY`
  - `QITECH_PRIVATE_KEY`
  - `QITECH_KEY_ID`
  - `QITECH_SOURCE_ACCOUNT_KEY`
  - `QITECH_WEBHOOK_SECRET` or `QITECH_WEBHOOK_TOKEN`
  - `QITECH_OPEN_TIMEOUT_SECONDS`
  - `QITECH_READ_TIMEOUT_SECONDS`
- StarkBank (feature-flagged):
  - `STARKBANK_WEBHOOK_SECRET` or `STARKBANK_WEBHOOK_TOKEN`

### Party onboarding metadata
- Account opening payload:
  - `party.metadata.integrations.qitech.account_request_payload`
- Optional pre-provisioned escrow account:
  - `party.metadata.integrations.qitech.escrow_account`
- Destination account for EXCESS payout:
  - `party.metadata.integrations.qitech.payout_destination_account`

### Webhook reconciliation (idempotent)
- Endpoint format:
  - `/webhooks/escrow/QITECH/:tenant_slug`
  - `/webhooks/escrow/STARKBANK/:tenant_slug`
- Receipt table:
  - `provider_webhook_receipts` (tenant-scoped, unique by provider + event id)
- Payload replay handling:
  - Same provider event id + same payload: replay (`200`).
  - Same provider event id + different payload: conflict (`409`).
- Mismatch/failure queue:
  - `reconciliation_exceptions` stores unresolved webhook reconciliation exceptions for ops follow-up.

## Docs Generation

From `app/`:

- `rv ruby run -- script/generate_documentation.rb`

## Document Storage (ActiveStorage + GCS)
- Document evidence uses ActiveStorage attachments on `Document` and `KycDocument`.
- ActiveStorage direct upload endpoint:
  - `POST /rails/active_storage/direct_uploads`
- Receivable/KYC document APIs accept `blob_signed_id` (from direct upload) and persist the blob key as `storage_key`.
- Production storage service defaults to `google` (Google Cloud Storage) and can be overridden with:
  - `ACTIVE_STORAGE_SERVICE`

### GCS Configuration
- Configure under Rails credentials (`Rails.app.creds`) or environment variables:
  - `gcs.project` or `GCS_PROJECT`
  - `gcs.bucket` or `GCS_BUCKET`
  - `gcs.credentials_path` or `GCS_CREDENTIALS_PATH`
- Service definitions live in `config/storage.yml`.

## Composable Receivables Model
- Shared core table: `receivables`.
- Extensible type dimension: `receivable_kinds`.
- Type-specific detail via associated tables (physician/supplier and future types).
- Shared allocation model: `receivable_allocations`.
- Shared statistics model: `receivable_statistics_daily`.

## Compliance Baseline
- IP logging for security-relevant actions.
- Signature action inside platform with confirmation code flow.
- 7-year retention for financial/audit/security records.

## Security Baseline (Financial)
- CSRF verification strategy uses `Sec-Fetch-Site` (`:header_only`) with `protect_from_forgery` exception mode.
- Production enforces HTTPS (`force_ssl`) with HSTS and strict same-site cookie protection.
- Web session cookie (`session_id`) is encrypted, `HttpOnly`, `SameSite=Strict`, and time-limited (`SESSION_TTL_HOURS`, default 12h).
- Session records are rejected server-side after TTL expiration.
- Host header allowlist can be configured via:
  - `security.allowed_hosts` or `APP_ALLOWED_HOSTS`
- CSP is enabled globally; optional allowlist extensions are configurable via:
  - `security.csp_connect_src` or `CSP_CONNECT_SRC`
  - `security.csp_img_src` or `CSP_IMG_SRC`
- `ops_admin` users must pass WebAuthn (`webauthn-ruby`) second-factor verification to access `/admin/dashboard`.

## PII Encryption (Rails Native)
- PII fields are encrypted at rest via Active Record Encryption (AES-256-GCM).
- Encryption keys must come from Rails credentials (`Rails.app.creds`):
  - `active_record_encryption.primary_key`
  - `active_record_encryption.deterministic_key`
  - `active_record_encryption.key_derivation_salt`
- Generate candidate keys:
  - `cd app && rv ruby run -- -S bundle exec rails db:encryption:init`
- Store keys in credentials:
  - `cd app && rv ruby run -- -S bundle exec rails credentials:edit`
- In production, app boot fails if encryption keys are missing.
