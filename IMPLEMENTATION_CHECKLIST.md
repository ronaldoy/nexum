# Implementation Checklist

Execution checklist derived from `AI_PLAN.md`, with practical priorities and current status.

## P0 - Immediate (Foundational Contract and Operability)

- [x] Add `/health` liveness endpoint and keep `/ready` readiness endpoint.
  - Implemented in `app/config/routes.rb` and `app/app/controllers/health_controller.rb`.
  - Tested in `app/test/controllers/health_controller_test.rb`.

- [x] Establish OpenAPI v1 baseline with deterministic error model and idempotency header conventions.
  - Implemented in `docs/openapi/v1.yaml`.

- [x] Publish OpenAPI baseline in API docs distribution (render or serve from app).
  - Implemented via `/docs/openapi/v1` and `/docs/openapi/v1.yaml`.

## P1 - Core Domain Completeness (Phase 1 Critical Gaps)

- [x] Introduce `roles` and `user_roles` schema/models and migrate from single `users.role` field.
- [x] Add `assignment_contracts` schema/model and lifecycle events.
- [x] Add API endpoint for signed document metadata attachment on receivables flow.
- [x] Add explicit `ActionIpLog` coverage tests for all privileged/security-sensitive actions.

## P2 - Integration and Reconciliation (Phase 2)

- [ ] Outbox publisher workers with retry/backoff/dead-letter semantics.
- [ ] Signed/idempotent webhook handlers.
- [ ] Payment provider adapters (QI Tech, Stark Bank) with tenant routing.
- [ ] FIDC funding/settlement adapter.
- [ ] Reconciliation pipeline and mismatch queue/reporting.

## P3 - Supplier Portal Readiness (Phase 3)

- [ ] Supplier-specific API surfaces and policy hardening tests.
- [ ] Compliance audit export endpoints/jobs.
- [ ] Portal UX acceptance: responsive validation and accessibility audit pass.

## P4 - Hardening and Scale (Phase 4)

- [ ] Partition strategy for append-only large tables.
- [ ] Feature-flag framework for controlled financial rollouts.
- [ ] SLO/alerts/runbooks and staging validation.
- [ ] 7-year retention archival workflow and restore drill.

## Notes

- Governance items such as branch protection and required checks must be configured in the VCS/CI platform, not only in repository code.
- This checklist is intentionally execution-oriented and can be expanded into sprint tickets.
