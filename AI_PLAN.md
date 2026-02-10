# AI_PLAN.md

## Purpose
Shared execution plan for human + AI agents implementing the receivables platform.

## Scope
- Rails 8.2 (edge during build, latest stable 8.2.x before launch) monolith (web + JSON API) with PostgreSQL 18.1.
- Integrations: hospital ERPs, payment providers, FIDC, e-sign.
- Supplier portal API support.
- Physician channel integration via external platform APIs.
- Web UI standard: Hotwire (`Turbo` + `Stimulus`) for interactive interfaces.
- CSS standard: Rails-native CSS/SCSS (no Tailwind), with design tokens and reusable components.
- Async standard: Solid Queue (default), with minimal extra infrastructure.
- Provider strategy: adapter-based and tenant-configurable (QI Tech and Stark Bank in v1).

## Global Constraints
- Package/dependency management must use `rv`.
- Financial precision: BigDecimal + NUMERIC only.
- Monetary/rate JSON fields as strings.
- Currency policy: BRL-only in phase 1 (reject any non-BRL currency code).
- Financial rounding: `ROUND_UP`.
- Append-only events/ledger/document_events.
- PostgreSQL RLS + FORCE RLS.
- API-only data access.
- Idempotency is mandatory on all write operations and integrations.
- Full auditability per receivable.
- UI language: Brazilian Portuguese (`pt-BR`) with proper accents in all user-facing content.
- Brazilian state options must use canonical `UF - Nome` format (abbreviation first), and CRM/address state values must be restricted to the official UF list.
- Code and technical artifacts: English only (identifiers, API fields, DB schema, logs).
- UI must be beautiful, consistent, and fully responsive (mobile + desktop).
- Tailwind CSS is not allowed.
- Prefer Rails omakase defaults first; deviations must be justified by measured needs.
- Authentication and secrets management must use Rails native capabilities only in phase 1.
- Do not introduce external IdP or external secret manager tools in phase 1.
- Secrets/config access must use `Rails.app.creds` with Rails 8.2 precedence rules.
- Business timezone: `America/Sao_Paulo`.
- Daily cutoff: `23:59:59` local timezone, payment target next business day.
- Log retention for financial/audit/security records: 7 years.
- Schema design must remain composable for new receivable types with shared core logic and shared statistics.

## Phase 0 - Foundations (Week 1)
### Deliverables
- Rails API project bootstrap.
- PostgreSQL 18.1 local/staging bootstrap and baseline migrations.
- Rails native authentication bootstrap (`bin/rails generate authentication`).
- First-party token model for integration APIs (managed internally in Rails).
- Rails credentials setup for environment secrets and key handling.
- Version policy setup: Rails 8.2 edge tracking plus release-gate checklist to pin stable 8.2.x before go-live.
- RLS helper functions and first policies.
- Solid Queue/Solid Cache baseline setup.
- OpenAPI baseline and error model conventions.
- Trunk-based development workflow setup (branch protection, mandatory checks).

### Exit Criteria
- `/health`, `/ready`, auth smoke tests pass.
- Native Rails auth flow and API token auth flow pass smoke tests.
- DB session context (`app.tenant_id`, `app.actor_id`, `app.role`) set per request.
- RLS policy test proves tenant isolation.

## Phase 1 - Core Receivables and Anticipation (Weeks 2-4)
### Deliverables
- Core entities:
  - users/roles/permissions
  - physicians with PF/PJ model support (PF, PJ unipessoal, PJ multiplo)
  - physician legal membership/authorization model
  - receivables
  - anticipation_requests
  - assignment_contracts
  - receivable_events (append-only)
  - ledger_entries (append-only)
  - documents/document_events
  - action IP logs
  - auth challenges for confirmation codes
  - outbox_events
- Endpoint set v1:
  - create/list receivables
  - request anticipation
  - attach signed document metadata
  - fetch full receivable history
- Signature/confirmation flows:
  - sign action in our own tool
  - confirmation code via email
  - confirmation code via WhatsApp
- Service objects for money-critical commands.
- Idempotency middleware/pattern.
- Append-only DB triggers and grants.

### Exit Criteria
- End-to-end anticipation flow works with immutable event + ledger writes.
- Repeated requests with same `Idempotency-Key` are safe.
- History query returns complete timeline with document events.
- IP logging is validated for all relevant security/financial actions.

## Phase 2 - Integrations and Reconciliation (Weeks 5-7)
### Deliverables
- Outbox publisher workers.
- Inbound webhook handlers (signed + idempotent).
- ERP ingestion adapter (performado events).
- Payment provider adapters:
  - QI Tech
  - Stark Bank
- Provider routing by tenant configuration.
- FIDC funding/settlement adapter.
- Reconciliation jobs and exception queue.

### Exit Criteria
- At-least-once delivery with dedup guarantees.
- Daily reconciliation report with mismatch categories.
- Operational dashboards for integration failures and retries.
- Provider failover/retry behavior validated with idempotent replay tests.

## Phase 3 - Supplier Portal Readiness (Weeks 8-9)
### Deliverables
- Supplier-facing APIs for receivables/anticipations/status/history.
- Fine-grained RBAC + RLS policy refinements.
- Performance and pagination hardening.
- Audit exports for compliance.
- Localization implementation for portal UI (`pt-BR`) and copy QA for correct accents.
- Hotwire implementation for supplier workflows (Turbo Frames/Streams + Stimulus).
- Rails-native CSS design system baseline and responsive component library for portal screens.

### Exit Criteria
- Supplier workflows fully supported via API.
- No cross-tenant or cross-actor data leakage in policy tests.
- Compliance-audit extracts available per receivable and per period.
- All supplier portal screens and user messages validated in Brazilian Portuguese with proper accents.
- Supplier portal validated as responsive on key mobile and desktop breakpoints.
- UI quality review approved (visual polish, accessibility, interaction quality).

## Phase 4 - Hardening and Scale (Weeks 10+)
### Deliverables
- Partition strategy for append-only tables.
- Key rotation and secret management hardening.
- SLOs, alerts, incident playbooks.
- Backfill/rebuild strategy for read models.
- Controlled rollout and feature flags.
- Pre-launch dependency freeze and explicit pin to stable Rails 8.2.x.
- Long-term retention strategy and archival process for 7-year compliance.

### Exit Criteria
- Recovery drills passed.
- Observability and alerting validated in staging.
- Production readiness review approved.

## Multi-Agent Workstreams
- Agent A: Data model, RLS, append-only constraints, migrations.
- Agent B: AuthN/AuthZ middleware, token verification, permission matrix.
- Agent C: Anticipation command flows, ledger posting, idempotency.
- Agent D: Integrations/outbox/webhooks/retries.
- Agent E: Test strategy, CI, observability, runbooks.

## Test Matrix (Mandatory)
- Unit:
  - rounding and interest
  - service invariants
- Integration:
  - DB transaction boundaries
  - RLS policy behavior
  - append-only trigger enforcement
  - idempotent endpoint behavior
  - IP logging and confirmation-code flow behavior
  - provider adapter conformance and idempotent retries
- E2E:
  - receivable lifecycle
  - anticipation + settlement
  - signed document tracking
  - reconciliation with simulated failures
  - PF/PJ physician confidentiality and authorization boundaries

## Open Decisions (Track Explicitly)
- Product-specific legal exceptions to default `ROUND_UP` policy.
- Event schema versioning policy.
- Canonical account chart for ledger.
- SLA targets for funding windows (D+1, D+0, immediate).
- Integration contract details per ERP/provider/FIDC.
- Messaging provider choice for WhatsApp delivery.
