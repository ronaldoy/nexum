# User ID UUID Migration Plan

Goal: migrate `users.id` from `bigint` to `uuid` safely, with zero data loss and controlled rollout.

## Current status

- Implemented now:
  - Phase 1 (`users.uuid_id`) via `app/db/migrate/20260219213000_add_uuid_references_for_users.rb`
  - Phase 2 (shadow UUID references on dependents)
  - Phase 3 baseline dual-write in model layer
- Still pending:
  - Phase 4+ (UUID-first reads, PK promotion, bigint cleanup)

## Scope

Tables and flows that reference `users.id` today:
- `sessions.user_id`
- `api_access_tokens.user_id`
- `partner_applications.created_by_user_id`
- any future FK to `users`
- authentication/session loading paths
- admin audit trails that include user identity

## Constraints

- Keep production writable during migration.
- Avoid long table locks on hot tables.
- Support rollback at each stage.
- Keep RLS/session context behavior unchanged.

## Phased rollout

1. Add parallel UUID column
- Add `users.uuid_id uuid` with default `gen_random_uuid()`.
- Add unique index on `users.uuid_id`.
- Backfill existing rows where `uuid_id` is null.
- Add `NOT NULL` after backfill.

2. Add shadow FK columns to dependents
- Add nullable UUID FK columns:
  - `sessions.user_uuid_id`
  - `api_access_tokens.user_uuid_id`
  - `partner_applications.created_by_user_uuid_id`
- Backfill from `users.uuid_id` using join updates in batches.
- Add indexes + FK constraints (`NOT VALID` then `VALIDATE CONSTRAINT`).

3. Dual-write in application layer
- Update models/services to write both bigint and uuid references.
- Keep reads on bigint first, with uuid parity checks in logs/metrics.
- Add migration guards that reject rows with mismatched bigint/uuid mapping.

4. Switch reads to UUID
- Update associations to use UUID foreign keys as primary read path.
- Keep bigint columns for fallback during bake period.
- Run parity checks and alert on drift.

5. Promote UUID as primary key
- Create new PK strategy:
  - either table swap approach (recommended for lower risk)
  - or in-place PK switch during maintenance window
- Repoint dependent FKs to UUID PK.
- Remove bigint FK usage from application code.

6. Cleanup
- Drop old bigint FK columns from dependents.
- Drop bigint `users.id` only after full verification and backup checkpoint.
- Regenerate schema/docs and update runbooks.

## Verification checklist

- All dependent rows have non-null UUID references.
- FK validations are green.
- App reads/writes succeed with UUID-only mode in staging.
- Authentication/session creation and lookup pass regression suite.
- Token issuance/revocation/admin actions pass regression suite.
- Audit logs keep traceability across the transition.

## Rollback strategy

- Until step 5, rollback by switching reads back to bigint and keeping dual-write.
- Keep bigint columns untouched until UUID mode is stable for at least one full release cycle.
- Snapshot DB before PK promotion step.
