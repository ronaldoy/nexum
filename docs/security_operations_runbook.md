# Security Operations Runbook

This runbook covers the operational controls that sit beside the Rails app and PostgreSQL schema hardening.

## PostgreSQL Role Separation

Production must use distinct roles:

- `nexum_runtime`
  - used by the Rails app
  - `NOSUPERUSER`
  - `NOBYPASSRLS`
  - must not own public tables
- `nexum_migrate`
  - used only for migrations and privileged DDL
  - should not be used by the running app
- `nexum_readonly`
  - optional reporting/read replicas
  - `SELECT` only on approved objects

Bootstrap variables:

- `POSTGRES_RUNTIME_USER` / `POSTGRES_RUNTIME_PASSWORD`
- `POSTGRES_MIGRATE_USER` / `POSTGRES_MIGRATE_PASSWORD`
- `POSTGRES_READONLY_USER` / `POSTGRES_READONLY_PASSWORD`
- `POSTGRES_SUPERUSER` / `POSTGRES_SUPERUSER_PASSWORD`

`../bin/db-bootstrap` provisions these roles and database grants. `app/bin/setup` and `app/bin/docker-entrypoint` automatically switch `db:prepare` to the migrate role when `POSTGRES_MIGRATE_USER` is present.

Verification commands:

```bash
cd app
rv ruby run -- -S bin/security-role-audit
rv ruby run -- -S bin/security-schema-audit
```

`/ready` also checks database-role and schema posture.

## Secret Rotation

Rotate these on a defined schedule and on any suspected exposure:

- Rails credentials master key and encrypted credentials
- partner application `client_secret`
- admin-issued API access tokens
- webhook HMAC secrets
- webhook bearer tokens, if temporarily enabled
- provider API credentials and signing keys

### Partner Application Secret Rotation

1. Open `/admin/partner_applications`.
2. Require passkey step-up.
3. Rotate the secret for the target application.
4. Deliver the new `client_secret` out-of-band.
5. Confirm previously issued partner tokens were revoked.
6. Confirm the partner can mint a fresh token from `/api/v1/oauth/token/:tenant_slug`.

### Admin API Token Rotation

1. Open `/admin/api_access_tokens`.
2. Require passkey step-up.
3. Issue a replacement token with the minimum scopes needed.
4. Update the consuming integration.
5. Revoke the previous token.

### Webhook Secret Rotation

1. Set the new tenant-scoped secret in Rails credentials or environment.
2. Update the provider-side webhook signing secret.
3. Send a signed test webhook.
4. Confirm `/ready` remains healthy and `provider_webhook_receipts` continue processing.
5. Remove the old secret.

## Continuous Assurance

On every PR and release:

- secret scanning
- Brakeman
- bundler-audit
- importmap audit
- database schema audit

Scheduled assurance:

- GitHub Actions workflow: `.github/workflows/security-assurance.yml`

Recommended cadence:

- Daily: scheduled assurance workflow
- Weekly: manual `bin/security-role-audit`
- Weekly: manual `rv ruby run -- -S bin/security-role-audit`
- Monthly: secret rotation review and stale credential cleanup
- Quarterly: backup restore drill and incident-response tabletop

## Backup and Restore Drill

At least quarterly:

1. Take a fresh production backup snapshot.
2. Restore it into an isolated environment.
3. Boot the app against the restored data.
4. Run:

```bash
cd app
rv ruby run -- -S bin/security-role-audit
rv ruby run -- -S bin/security-schema-audit
rv ruby run -- -S bundle exec rails test test/services/security/database_schema_audit_test.rb
```

5. Verify critical flows:
   - login
   - token issuance
   - webhook processing
   - receivable history access
   - anticipation confirmation

Document start time, end time, failures, and corrective actions.
