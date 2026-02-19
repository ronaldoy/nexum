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

- Backend: Rails 8.2 monolith (`app/`).
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
- Future provider stub already wired: `STARKBANK`.
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
- `QITECH_WEBHOOK_SECRET` or `QITECH_WEBHOOK_TOKEN`
- `QITECH_OPEN_TIMEOUT_SECONDS`
- `QITECH_READ_TIMEOUT_SECONDS`
- `STARKBANK_WEBHOOK_SECRET` or `STARKBANK_WEBHOOK_TOKEN`
- `ESCROW_DEFAULT_PROVIDER` (`QITECH` or `STARKBANK`)

For account opening, provide provider-specific payload in party metadata:

- `party.metadata.integrations.qitech.account_request_payload`
- Optional pre-provisioned account shortcut:
  - `party.metadata.integrations.qitech.escrow_account`
- EXCESS payout destination account:
  - `party.metadata.integrations.qitech.payout_destination_account`

## Main API endpoints

- `GET /health`
- `GET /ready`
- `POST /webhooks/escrow/:provider/:tenant_slug`
- `GET /admin/dashboard`
- `GET /admin/api_access_tokens`
- `POST /admin/api_access_tokens`
- `DELETE /admin/api_access_tokens/:id`
- `GET /api/v1/hospital_organizations`
- `GET /api/v1/receivables`
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
- Changelog and release notes source: `CHANGELOG.md`

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

Release policy:
- open a changelog entry under `## [Unreleased]`
- tag immutable releases as `vX.Y.Z`
- release workflow validates the matching `CHANGELOG.md` section before publishing

## Demo users

Tenant slug: `demo-br`  
Password: `Nexum@2026`
Default hospital organization seed code: `hospital-organization-main`

- `hospital_org_user@demo.nexum.capital` (organization managing multiple hospitals)
- `hospital_unit_user@demo.nexum.capital` (single hospital unit)
- `supplier_user@demo.nexum.capital`
- `physician_user@demo.nexum.capital`
- `fdic_user@demo.nexum.capital`
