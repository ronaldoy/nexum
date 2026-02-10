# Medilend App

Rails application for receivables anticipation platform.

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
   - `cd app && rv bundle install`
4. Run migrations:
   - `cd app && rv bundle exec bin/rails db:migrate`
5. Start app:
   - `cd app && rv bundle exec bin/rails server`

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
- `GET /ready` readiness check (database connectivity).
- `GET /api/v1/receivables` list receivables scoped by tenant context.
- `GET /api/v1/receivables/:id` fetch single receivable.
- `GET /api/v1/receivables/:id/history` full append-only timeline (events + document events).

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
