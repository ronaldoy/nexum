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

### Changed
- Direct upload idempotency now uses tenant-aware uniqueness in Active Storage blobs.
- Outbox dispatch now supports append-only retry/dead-letter tracking.
- Admin passkey verification now uses explicit strong-parameter allowlist.
- Kamal deploy config now fails closed for host and registry configuration (no insecure defaults).

## [0.1.0] - 2026-02-19

### Added
- Initial phase-1 Rails 8.2 platform foundations for receivables anticipation.
