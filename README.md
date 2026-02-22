# Nexum Platform

Receivables anticipation platform for healthcare operations in Brazil.

## What the system does

The platform models and executes the full anticipation lifecycle:

1. Receivable performance registration (`PERFORMED`).
2. Anticipation request and confirmation challenge issuance.
3. Funding/assignment lifecycle for FIDC exposure.
4. Signed document evidence attachment.
5. Settlement and reconciliation events.

The system supports:
- Multi-tenant isolation by `tenant_id`.
- Organizations owning multiple hospitals (`hospital_ownerships`).
- FIDC visibility of receivable origin (hospital + owning organization).
- Append-only audit/event history for financial traceability.

## Core architecture

- Backend: Rails 8.2 edge monolith (`app/`), tracking Rails main branch pre-stable.
- DB: PostgreSQL with enforced RLS + `FORCE ROW LEVEL SECURITY`.
- Money/rate precision:
  - Ruby: `BigDecimal`
  - PostgreSQL: `NUMERIC`
  - API: monetary/rate fields as strings
- Async/reliability:
  - Solid Queue
  - Outbox events
  - Endpoint idempotency (`Idempotency-Key`)
  - Reconciliation exception queue (`reconciliation_exceptions`)
- UI:
  - Rails + Hotwire
  - `pt-BR` UX copy for portal screens

## Security model

- Tenant context is set per request in DB session variables:
  - `app.tenant_id`
  - `app.actor_id`
  - `app.role`
- Sensitive tables are RLS protected.
- Ledger/event/audit tables are append-only where applicable.
- Privileged actions and money movement are IP-logged.
- `ops_admin` access to global `/admin/dashboard` requires a WebAuthn passkey step-up (second factor).
- Signed documents are stored with immutable evidence (`sha256`, `storage_key`, timestamps, actor).
- Third-party frontend integrations use OAuth 2.0 client credentials with short-lived Bearer tokens and scope allowlists (`partner_applications`).

## Third-party frontend authentication

- Admin creates partner credentials in:
  - `GET /admin/partner_applications`
  - `POST /admin/partner_applications`
- OAuth token issuance endpoint:
  - `POST /api/v1/oauth/token/:tenant_slug`
- Token grant supported:
  - `grant_type=client_credentials`
- Credential transport:
  - Standard HTTP Basic (`Authorization: Basic base64(client_id:client_secret)`) or body `client_id/client_secret`
- Token behavior:
  - short TTL (5..60 minutes, default 15)
  - scope subset issuance (`scope=...`)
  - secret rotation and deactivation revoke active issued tokens for the partner application
- New partner-facing endpoints for intake:
  - `POST /api/v1/physicians`
  - `GET /api/v1/physicians/:id`
  - `POST /api/v1/receivables`

## Hospital organizations and multi-hospital management

- `hospital_ownerships` links one organization party (`LEGAL_ENTITY_PJ`/`PLATFORM`) to hospital parties.
- Non-privileged organization actors can access receivables from owned hospitals through API visibility rules.
- FIDC and API responses include receivable provenance:
  - `hospital`
  - `owning_organization`
- New endpoint:
  - `GET /api/v1/hospital_organizations`

## Escrow payout integrations

- Escrow disbursement is provider-agnostic (`Integrations::Escrow` abstraction).
- Current provider implementation: `QITECH`.
- Future provider stub already wired: `STARKBANK` (feature-flagged off in v1).
- Trigger point:
  - On receivable settlement (`POST /api/v1/receivables/:id/settle_payment`), the system computes `beneficiary_amount` (excedente after anticipated/FIDC repayment) and emits `RECEIVABLE_ESCROW_EXCESS_PAYOUT_REQUESTED` into `outbox_events`.
- Worker dispatch:
  - `Outbox::DispatchEvent` routes the event through `Outbox::EventRouter` and executes escrow provisioning/payout with retry/dead-letter semantics.
- Persistence:
  - `escrow_accounts`: provider account linkage per party.
  - `escrow_payouts`: idempotent payout attempts and provider references.
  - `provider_webhook_receipts`: webhook idempotency and payload evidence.
  - `reconciliation_exceptions`: mismatch/failure queue for operational follow-up.
- Receivable provenance included in payout payload:
  - hospital (`debtor_party`)
  - owning organization (when mapped in `hospital_ownerships`)
- Destination account validation:
  - EXCESS payout destination must belong to the same CPF/CNPJ as the recipient party (hard validation before transfer).

### QI Tech setup

Configure via Rails credentials (`integrations.qitech.*`) or environment:

- `QITECH_BASE_URL`
- `QITECH_API_CLIENT_KEY`
- `QITECH_PRIVATE_KEY`
- `QITECH_KEY_ID`
- `QITECH_SOURCE_ACCOUNT_KEY`
- `QITECH_WEBHOOK_SECRET__<TENANT_SLUG>` or `QITECH_WEBHOOK_TOKEN__<TENANT_SLUG>`
- `QITECH_OPEN_TIMEOUT_SECONDS`
- `QITECH_READ_TIMEOUT_SECONDS`
- `STARKBANK_WEBHOOK_SECRET__<TENANT_SLUG>` or `STARKBANK_WEBHOOK_TOKEN__<TENANT_SLUG>`
- `ESCROW_DEFAULT_PROVIDER` (`QITECH` in v1)
- `ESCROW_ENABLE_STARKBANK` (`false` by default)

Webhook auth credentials are tenant-scoped and resolved from:
- `integrations.<provider>.webhooks.tenants.<tenant_slug>.webhook_secret`
- `integrations.<provider>.webhooks.tenants.<tenant_slug>.webhook_token`

For account opening, provide provider-specific payload in party metadata:

- `party.metadata.integrations.qitech.account_request_payload`
- Optional pre-provisioned account shortcut:
  - `party.metadata.integrations.qitech.escrow_account`
- EXCESS payout destination account:
  - `party.metadata.integrations.qitech.payout_destination_account`

## Main API endpoints

- `GET /health`
- `GET /ready`
- `POST /api/v1/oauth/token/:tenant_slug`
- `POST /webhooks/escrow/:provider/:tenant_slug`
- `GET /admin/dashboard`
- `GET /admin/api_access_tokens`
- `POST /admin/api_access_tokens`
- `DELETE /admin/api_access_tokens/:id`
- `GET /admin/partner_applications`
- `POST /admin/partner_applications`
- `POST /admin/partner_applications/:id/rotate_secret`
- `PATCH /admin/partner_applications/:id/deactivate`
- `GET /api/v1/hospital_organizations`
- `POST /api/v1/physicians`
- `GET /api/v1/physicians/:id`
- `GET /api/v1/receivables`
- `POST /api/v1/receivables`
- `GET /api/v1/receivables/:id`
- `GET /api/v1/receivables/:id/history`
- `POST /api/v1/receivables/:id/settle_payment`
- `POST /api/v1/receivables/:id/attach_document`
- `POST /api/v1/anticipation_requests`
- `POST /api/v1/anticipation_requests/:id/issue_challenges`
- `POST /api/v1/anticipation_requests/:id/confirm`
- `POST /api/v1/kyc_profiles`
- `GET /api/v1/kyc_profiles/:id`
- `POST /api/v1/kyc_profiles/:id/submit_document`

## Documentation

- OpenAPI contract: `docs/openapi/v1.yaml`
- Generated API reference: `docs/api_reference.md`
- Generated DB model docs: `docs/database_model.md`
- Planned migration strategy for `users.id` UUID transition: `docs/user_id_uuid_migration_plan.md`
- Changelog and release notes source: `CHANGELOG.md`
- Upright monitor guide: `monitoring/upright/README.md`

Regenerate API and DB docs:

```bash
cd app
rv ruby run -- script/generate_documentation.rb
```

## Local run

```bash
./bin/db-up
./bin/db-bootstrap
cd app
rv clean-install
rv ruby run -- -S bin/rails db:migrate
rv ruby run -- -S bin/rails db:seed
rv ruby run -- -S bin/rails server
```

## CI, release, and deploy

- CI workflow: `.github/workflows/ci.yml`
- Release workflow (tag-driven): `.github/workflows/release.yml`
- Dependabot: `.github/dependabot.yml`
- Kamal scaffold: `app/config/deploy.yml`
- Upright monitor deploy scaffold: `monitoring/upright/config/deploy.yml`

### Secret scanning guardrails

- Repository scanning command:
  - `./bin/secret-scan --no-banner`
- Local pre-commit enforcement:
  - `./bin/setup-git-hooks`
- Pre-commit hook scans staged changes with `gitleaks` (or Docker fallback) and blocks commits on detected secrets.

## Monitoring (37signals Upright)

- Dedicated monitor service: `monitoring/upright`
- Tooling: Upright + Prometheus + Alertmanager + OpenTelemetry collector (via Kamal accessories)
- Nexum probe definitions: `monitoring/upright/probes/http_probes.yml.erb`
- Probe scheduling: `monitoring/upright/config/recurring.yml`
- Site topology: `monitoring/upright/config/sites.yml`

Quick start:

```bash
cd monitoring/upright
cp .env.example .env
rv clean-install
docker compose up -d
rv ruby run -- -S bin/rails db:prepare
PORT=3100 ADMIN_PASSWORD=dev-upright UPRIGHT_HOSTNAME=upright.localhost NEXUM_APP_BASE_URL=http://localhost:3000 rv ruby run -- -S bin/dev
```

Run Nexum (`app/`) locally on `http://localhost:3000` first so Upright probes the real app.

Release policy:
- open a changelog entry under `## [Unreleased]`
- tag immutable releases as `vX.Y.Z`
- release workflow validates the matching `CHANGELOG.md` section before publishing

## Demo users

Local/demo only (`development` or `test`):

Tenant slug: `demo-br`  
Password: defined by `DEMO_SEED_PASSWORD` (or generated at seed time if unset)
Default hospital organization seed code: `hospital-organization-main`

- `hospital_org_user@demo.nexum.capital` (organization managing multiple hospitals)
- `hospital_unit_user@demo.nexum.capital` (single hospital unit)
- `supplier_user@demo.nexum.capital`
- `physician_user@demo.nexum.capital`
- `fdic_user@demo.nexum.capital`

Security notes:
- `SHOW_DEMO_CREDENTIALS` controls whether demo accounts are rendered on the login page.
- Demo seeds are blocked in production unless `ALLOW_DEMO_SEEDS=true`.
