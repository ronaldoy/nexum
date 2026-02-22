# Nexum Upright Monitor

Dedicated Upright service used to monitor Nexum availability and critical web/API health endpoints.

## Architecture

- Runs as an independent Rails app (`monitoring/upright`).
- Uses Solid Queue, Solid Cache, and Solid Cable.
- Deploys with Kamal using `monitoring/upright/config/deploy.yml`.
- Probes target Nexum through `NEXUM_APP_BASE_URL`.

This follows the official Upright recommendation from 37signals: keep monitoring isolated from the primary app runtime.

## Local setup

```bash
cd monitoring/upright
cp .env.example .env
rv clean-install
docker compose up -d
rv ruby run -- -S bin/rails db:prepare
PORT=3100 ADMIN_PASSWORD=dev-upright UPRIGHT_HOSTNAME=upright.localhost NEXUM_APP_BASE_URL=http://localhost:3000 rv ruby run -- -S bin/dev
```

Run Nexum app in another terminal on `http://localhost:3000` before starting probes.

Access:

- Global dashboard: `http://app.upright.localhost:3100`
- Site view (Sao Paulo): `http://gru.upright.localhost:3100`

Default login user is `admin`; password comes from `ADMIN_PASSWORD`.

## Probe configuration

- HTTP probes: `monitoring/upright/probes/http_probes.yml.erb`
- Site locations: `monitoring/upright/config/sites.yml`
- Schedules: `monitoring/upright/config/recurring.yml`

Current probes monitor:

- `GET /up`
- `GET /ready`
- `GET /session/new`

`/ready` in Nexum also covers security readiness and will return `503` when:

- the application DB role is `SUPERUSER` or has `BYPASSRLS`.
- rolling `idempotency.conflict` volume exceeds the configured threshold.

This lets Upright + Alertmanager page on these regressions using the existing readiness probe.

## Production deploy (Kamal)

From `monitoring/upright`:

```bash
rv ruby run -- -S bin/kamal setup
rv ruby run -- -S bin/kamal deploy
```

Required variables/secrets are documented in:

- `monitoring/upright/.env.example`
- `monitoring/upright/config/deploy.yml`

Production safety:

- `UPRIGHT_HOSTNAME` is mandatory outside local environments.
- OIDC is required in production by default (`OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`).
- Static credentials in production require explicit emergency override:
  - `UPRIGHT_AUTH_PROVIDER=static_credentials`
  - `UPRIGHT_ALLOW_STATIC_AUTH_IN_PRODUCTION=true`
  - `ADMIN_PASSWORD` with a non-default value
