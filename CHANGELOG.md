# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog and Semantic Versioning.

## [Unreleased]

### Added
- GitHub Actions CI workflow at repository root.
- Release workflow with changelog gate and GitHub release publication.
- Kamal deployment scaffold for production rollout.
- Escrow webhook ingestion endpoint with signature verification, idempotent receipts, and payout/account reconciliation.
- Ops admin token lifecycle UI/endpoints for tenant-scoped API access tokens (list/create/revoke).
- Reconciliation exception queue (`reconciliation_exceptions`) surfaced in admin dashboard for mismatch/failure follow-up.
- OAuth 2.0 client-credentials integration access via `partner_applications`, including admin management UI, secret rotation/deactivation, and scoped token issuance.
- API endpoints for third-party intake of physicians and receivables (`POST /api/v1/physicians`, `GET /api/v1/physicians/:id`, `POST /api/v1/receivables`).
- UUID migration strategy document for `users.id` transition (`docs/user_id_uuid_migration_plan.md`).

### Changed
- Direct upload idempotency now uses tenant-aware uniqueness in Active Storage blobs.
- Outbox dispatch now supports append-only retry/dead-letter tracking.
- Admin passkey verification now uses explicit strong-parameter allowlist.
- Kamal deploy config now fails closed for host and registry configuration (no insecure defaults).
- OpenAPI/API reference and DB model documentation now include partner OAuth, physician intake, receivable creation, and partner application schema updates.
- UUID rollout for users started in production-safe staged mode: added `users.uuid_id`, shadow UUID references on dependent tables, backfill, and dual-write model synchronization.

## [0.1.0] - 2026-02-19

### Added
- Initial phase-1 Rails 8.2 platform foundations for receivables anticipation.
