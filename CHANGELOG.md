# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog and Semantic Versioning.

## [Unreleased]

### Added
- GitHub Actions CI workflow at repository root.
- Release workflow with changelog gate and GitHub release publication.
- Kamal deployment scaffold for production rollout.

### Changed
- Direct upload idempotency now uses tenant-aware uniqueness in Active Storage blobs.
- Outbox dispatch now supports append-only retry/dead-letter tracking.

## [0.1.0] - 2026-02-19

### Added
- Initial phase-1 Rails 8.2 platform foundations for receivables anticipation.
