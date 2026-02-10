# AGENTS.md

## Project Context
- Product: plataforma de antecipacao de recebiveis performados.
- Participants: hospitals, physicians (PF/CPF and PJ/CNPJ structures), suppliers, FIDC.
- Frontends:
  - Supplier portal is part of this platform.
  - Physician frontend is external (another platform).
- Core flows:
  - Receivable performance validation.
  - Anticipation request.
  - Funding.
  - Settlement and reconciliation.

## Chosen Stack (Phase 1)
- Backend: Rails 8.2 (edge now, pin to latest stable 8.2.x before production launch) monolith (web + JSON API).
- Package management: `rv` (mandatory for dependency workflows).
- Jobs: Solid Queue (default).
- Cache: Solid Cache (default).
- Realtime: Solid Cable when realtime features are required.
- Database: PostgreSQL 18.1.
- API-first architecture for partner/integration endpoints.
- UI architecture: Rails + Hotwire (`Turbo` + `Stimulus`) for server-driven interactive interfaces.
- CSS approach: Rails-native CSS (no Tailwind) with design tokens and reusable components.
- Assets/runtime approach: Rails defaults first (Propshaft/importmap) unless a clear need justifies deviation.
- Deployment preference: Kamal-first operational model.

## Delivery Workflow
- Use trunk-based development with short-lived branches.
- `main` must be protected and merge only via reviewed PR.
- Required checks before merge:
  - test suite
  - linters/static checks
  - security checks
- Use feature flags for incremental rollout of financial features.
- Tag every production release with an immutable version tag and changelog entry.

## Rails Version Policy
- Build and validate features on Rails 8.2 edge during pre-launch.
- Before production launch, pin to the latest stable Rails 8.2.x patch release.
- Do not ship production on an unpinned edge SHA.
- If a blocking regression appears in edge, freeze upgrades and evaluate temporary rollback path.

## Why Rails
- Team productivity is the primary driver.
- Expected volume for phase 1 (~5,000 tx/day) does not require high-throughput specialization.
- Main risks are financial correctness, auditability, and reconciliation, not raw framework throughput.
- Prefer Rails "omakase" defaults and introduce extra infrastructure only when metrics justify it.

## Non-Negotiable Rules

### Financial Precision
- Never use float/double for money or interest.
- System currency is fixed to Brazilian Real (`BRL`) in phase 1.
- Do not implement multi-currency conversion or FX logic in phase 1.
- Ruby domain types: `BigDecimal`.
- PostgreSQL types:
  - money amounts: `NUMERIC(18,2)` (or stricter per field needs).
  - rates: `NUMERIC(12,8)` (or stricter per policy).
- JSON API: send/receive monetary and rate fields as strings.
- Currency fields in API payloads must be `BRL`; reject any other currency code.
- Rounding policy must be explicit and centralized: `ROUND_UP` for financial operations unless legal/compliance requires a stricter rule per product.

### Time and Settlement Rules
- Business timezone for users and business rules: `America/Sao_Paulo`.
- Daily operational cutoff is `23:59:59` (`America/Sao_Paulo`).
- Payment execution target: next business day after effective processing cutoff.
- Calendar/business-day logic must handle national and local holidays explicitly.

### Language and Localization
- User interface language must be Brazilian Portuguese (`pt-BR`).
- All user-facing text must use proper accents and correct Portuguese grammar.
- Dates, currency, and number formatting in UI must follow `pt-BR` conventions.
- For Brazilian state selections in UI, use the canonical format `UF - Nome` (example: `SP - São Paulo`), with abbreviation first.
- CRM state fields and any address state fields must be validated against the Brazilian UF list only.
- Code must be written in English:
  - class/module/function/variable names
  - database table/column names
  - API paths and field names
  - internal logs and technical docs
- API error responses must expose stable machine-readable codes in English; UI is responsible for localized Portuguese messages.
- Translation keys must be in English and mapped to Portuguese strings for UI rendering.

### UI and UX Standards
- Use Hotwire by default for interactive web interfaces:
  - Turbo Drive/Turbo Frames/Turbo Streams for navigation and partial updates.
  - Stimulus for focused client-side behavior.
- Do not use Tailwind CSS.
- Use Rails-native CSS/SCSS with a shared design token system and reusable components/partials.
- Interfaces must be beautiful and intentionally designed, not generic scaffolding.
- All screens must be fully responsive and usable on mobile and desktop breakpoints.
- Use a consistent design system:
  - typography scale
  - spacing scale
  - color tokens
  - component states (hover/focus/disabled/error/loading)
- Accessibility is required:
  - semantic HTML
  - keyboard navigation
  - visible focus states
  - sufficient color contrast
- Performance guardrail:
  - avoid heavy SPA behavior when Hotwire can deliver equivalent UX.

### Append-Only and Full History
- History and ledger tables are append-only.
- No `UPDATE`/`DELETE` in:
  - events table(s)
  - ledger table(s)
  - document event table(s)
- Corrections must be compensating events/entries.
- Every material action must generate auditable event(s).
- Signed documents must be tracked with immutable evidence:
  - storage key
  - sha256 hash
  - signer identity
  - signature timestamp
  - provider envelope/reference id
- Signature action must be performed in our own platform flow.
- Every signature action must require confirmation code verification sent via both email and WhatsApp.
- IP logging is mandatory for every relevant action (authentication, authorization, signature, money movement, admin actions).

### PostgreSQL RLS
- Enforce `ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY` on all sensitive tables.
- Tenant and actor isolation are mandatory.
- Request scope must set DB session context in transaction:
  - `SET LOCAL app.tenant_id = ...`
  - `SET LOCAL app.actor_id = ...`
  - `SET LOCAL app.role = ...`
- Application access must happen only via API (no direct client DB access).

### Authentication and Authorization
- Use Rails native authentication (`bin/rails generate authentication`) for web users.
- Password hashing standard: Argon2id via `has_secure_password algorithm: :argon2`.
- Use Rails native session/cookie auth for portal/backoffice flows.
- For integration APIs, use first-party application tokens managed by Rails (no external IdP).
- Token lifecycle and revocation must be implemented in-app and audited.
- Role/scope-based authorization in API and UI.
- MFA required for privileged users.
- All privileged actions must be auditable.
- Required access profiles in v1:
  - `hospital_admin`
  - `supplier_user`
  - `ops_admin`
  - `physician_pf_user`
  - `physician_pj_admin`
  - `physician_pj_member`

### Secrets and Key Management
- Use Rails native secrets management only:
  - Rails credentials (`config/credentials*.yml.enc`)
  - encrypted configuration and environment-specific credentials
- Use `Rails.app.creds` as the unified application API for configuration lookup.
- Secrets lookup precedence should follow Rails 8.2 behavior (`ENV` first; `.env` in development; encrypted credentials fallback).
- Do not use external secret managers in phase 1.
- Keep master keys outside source control and rotate credentials/keys with documented runbooks.

### Idempotency and Reliability
- Idempotency is mandatory end-to-end.
- All mutating API endpoints must require `Idempotency-Key`.
- Outbox pattern required for external integrations.
- Integration workers must support retries with backoff and dead-letter handling.
- Webhook handlers must be idempotent and signed/verified.
- Queue and async processing should use Solid Queue by default; introduce Sidekiq/Redis only with explicit justification.
- Provider connectors (payments, FIDC, messaging) must implement idempotency keys and replay-safe behavior.

## Domain Boundaries
- `Cadastro/Identity`: hospitals, physicians, suppliers, legal entities, role assignments.
- `Physician Legal Model`: PF (CPF), PJ unipessoal, PJ multiplo with partner/admin/member relationships and confidentiality boundaries.
- `Receivables`: performado lifecycle and eligibility.
- `Anticipation`: terms, request, approval, funding.
- `Payments/Ledger`: postings, settlement, fees, splits.
- `Documents`: signature lifecycle and evidence.
- `Reconciliation`: bank/provider/FIDC matching and exceptions.
- `Audit/Compliance`: immutable trace, AML/PLD controls.
- `Integrations`: hospital ERP, payment providers, FIDC, signature provider, communication providers (email/WhatsApp).

## Data Model Requirements (Minimum)
- Schema must be composable:
  - shared core `receivables` model for all receivable types
  - pluggable type definitions (`receivable_kinds`)
  - optional type-specific detail tables for specialized attributes
  - shared allocation/event/ledger/statistics layers reused across all types
- `users`
- `roles`
- `user_roles`
- `physicians`
- `physician_profiles_pf`
- `physician_entities_pj`
- `physician_pj_memberships`
- `physician_pj_authorizations`
- `receivables`
- `anticipation_requests`
- `assignment_contracts`
- `ledger_entries` (double-entry)
- `receivable_events` (append-only full history)
- `documents`
- `document_events` (append-only)
- `action_ip_logs`
- `auth_challenges` (email/WhatsApp confirmation codes)
- `outbox_events`
- `snapshot/projection` tables for fast read models

## API Design Rules
- Versioned REST endpoints (`/api/v1/...`).
- Contract-first (OpenAPI).
- Error model must be deterministic and machine-readable.
- Monetary fields and rates must be strings in request/response bodies.
- Include correlation/request ids for tracing.

## Supplier Portal and Physician Integration
- Supplier portal consumes internal APIs with same auth and audit standards.
- Physician operations come from external frontend/API clients:
  - enforce partner/client auth
  - strict scope checks
  - rate limits and replay protection
  - strict PF/PJ confidentiality rules (no cross-visibility beyond allowed legal scope)

## Integration Providers
- Payment provider integration must be provider-agnostic via adapter interface.
- Supported providers in v1:
  - QI Tech
  - Stark Bank
- Different customers may use different providers; provider selection must be tenant-configurable.
- Provider operations must support deterministic retries and idempotency.

## Compliance and Retention
- Logging standard must meet Central Bank-level audit expectations for traceability.
- Retain audit, financial, and security-relevant logs/events for 7 years.
- Retention policy must include immutable storage strategy and secure archival.

## Development Rules
- Use `rv` for Ruby and dependency workflows.
- Install/update gems with `rv clean-install` (or `rv ruby run -- -S bundle install` when needed).
- Run Rails/Bundler commands through `rv ruby run -- -S ...` to keep the pinned Ruby version.
- Keep core financial logic in service/application layer, not in ORM callbacks.
- Keep SQL explicit for critical monetary operations.
- Use DB constraints and triggers as final guardrails, not only app code.
- Add automated tests for:
  - rounding/interest calculations
  - idempotency
  - RLS isolation
  - append-only enforcement
  - compensation flows

## Definition of Done (Financial Features)
- Decimal-safe logic end-to-end.
- Append-only invariants enforced at DB level.
- RLS policies tested and passing.
- Full audit trail generated and queryable per receivable.
- Signed document evidence linked and immutable.
- Reconciliation scenario tests included.
- Observability in place (logs, metrics, traces, alerts).
- UI copy validated in `pt-BR` with proper accents in all user-facing screens/messages.
- Web UI delivered with Hotwire and validated as responsive on mobile and desktop.
- UI quality review passed (visual consistency, accessibility, and interaction quality).

## Notes
- The `app/` Rails application is the implementation source of truth.
- The root `sql/001_schema.sql` file is legacy reference material; use Rails migrations in `app/db/migrate` for active schema evolution.
- Rails API direction in this file is the source of truth for implementation decisions unless superseded by an explicit product/engineering decision record.
