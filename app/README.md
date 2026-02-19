# Nexum Capital App

Rails application for receivables anticipation platform.

For full architecture, domain flow, and demo walkthrough see root `README.md`.

## Stack
- Rails 8.2 edge during build (pin stable 8.2.x before launch)
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
- `GET /api/v1/receivables` list receivables scoped by tenant context.
- `GET /api/v1/hospital_organizations` list organizations and managed hospitals.
- `GET /api/v1/receivables/:id` fetch single receivable.
- `GET /api/v1/receivables/:id/history` full append-only timeline (events + document events).
- `GET /docs/openapi/v1` serves OpenAPI v1 contract.
- OpenAPI source file: `../docs/openapi/v1.yaml`.
- Generated API reference: `../docs/api_reference.md`.
- Generated DB model docs: `../docs/database_model.md`.

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
