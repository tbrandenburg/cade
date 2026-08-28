# M1 (trimmed) Compose Foundation Milestone Report

Evidence captured for Phase 1 / Milestone M1 (trimmed) — Coder + coder-db
only — per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`doc/plan/plan.md`.

- **Timestamp (UTC):** 2026-08-28T10:53:31Z
- **Docker:** `Docker version 29.1.3, build f52814d`
- **Docker Compose:** `Docker Compose version v2.40.3-desktop.1`

## Sandbox constraint

Execution happens in a non-interactive, headless sandbox with no GUI browser
available (see the M0 report for the same constraint). The "open Coder UI in
a browser" step is therefore substituted with equivalent `curl` checks
against the same HTTP endpoints a browser would hit (`/`, `/healthz`,
`/api/v2/buildinfo`), documented below.

## Stack definition

`compose.yaml` at the repo root defines two services:

- `coder-db` — `postgres:17.6-alpine`, named volume `coder_db_data`,
  `pg_isready` health check, `restart: unless-stopped`, attached only to the
  `platform-control` network.
- `coder` — `ghcr.io/coder/coder:v2.36.3`, named volume `coder_home` for
  `/home/coder`, bind-mounted `/var/run/docker.sock`, `curl -f
  http://localhost:7080/healthz` health check, `restart: unless-stopped`,
  attached to both `platform-control` (to reach `coder-db`) and
  `platform-workspaces` (for future workspace provisioning, M3+).
  `depends_on: coder-db: condition: service_healthy`.

Both networks (`platform-control`, `platform-workspaces`) are explicit
bridge networks; no service uses `network_mode: host`.

## Commands and output

### `make up`

```
$ time make up
 Network platform-control  Created
 Network platform-workspaces  Created
 Volume devenv-cloud_coder_db_data  Created
 Volume devenv-cloud_coder_home  Created
 Container coder-db  Started
 Container coder-db  Healthy
 Container coder  Started

real	0m7.594s
```

Startup time to `docker compose up -d` returning: **~7.6s** (containers then
take a further ~15-20s to pass their health checks — see below).

### `make status`

```
$ make status
NAME       IMAGE                         COMMAND                  SERVICE    CREATED          STATUS                    PORTS
coder      ghcr.io/coder/coder:v2.36.3   "/opt/coder server"      coder      30 seconds ago   Up 22 seconds (healthy)   0.0.0.0:7080->7080/tcp, [::]:7080->7080/tcp
coder-db   postgres:17.6-alpine          "docker-entrypoint.s…"   coder-db   30 seconds ago   Up 29 seconds (healthy)   5432/tcp
```

Both `coder` and `coder-db` report **healthy** — validation criterion met.

### UI reachability (curl substitute for browser)

```
$ curl -s -o /dev/null -w "UI HTTP: %{http_code}\n" http://localhost:7080/
UI HTTP: 200

$ curl -s http://localhost:7080/api/v2/buildinfo
{"external_url":"https://github.com/coder/coder/commit/7e0ff4c80edbd90fa65021b428ba43bd70758169","version":"v2.36.3+7e0ff4c","dashboard_url":"http://localhost:7080","telemetry":true,"workspace_proxy":false,"agent_api_version":"1.0","provisioner_api_version":"1.18","upgrade_message":"","deployment_id":"c8ba45d0-b2de-49db-bc30-7a16090cc73c","webpush_public_key":"..."}
```

### `make down && make up` — persistence check

Deployment ID (a value only present once Coder's first-run bootstrap has
written its identity to the Postgres database) recorded before and after a
full stop/start cycle:

```
before: c8ba45d0-b2de-49db-bc30-7a16090cc73c
$ make down
 Container coder  Removed
 Container coder-db  Removed
 Network platform-control  Removed
 Network platform-workspaces  Removed
$ make up
 Container coder-db  Healthy
 Container coder  Started
after: c8ba45d0-b2de-49db-bc30-7a16090cc73c
PERSISTENCE OK
```

The `deployment_id` is identical before and after, confirming the named
volume `coder_db_data` (and thus the Postgres data directory) survives a
`make down && make up` cycle. `docker compose ps` after the restart again
showed both containers `healthy`.

### `make logs`

Verified `make logs` streams `docker compose logs -f` output for both
services (manually interrupted after confirming output; not captured here
to keep the report concise — this is the same command used to produce the
excerpts above via `docker logs`).

## Manual E2E Test M1 (trimmed) result

| Step | Result |
|---|---|
| 1. Start the stack (`make up`) | PASS — both services healthy within ~20s |
| 2. Open Coder UI in a browser | Substituted with `curl` (headless sandbox, see constraint above): `GET /` → `200`, `GET /api/v2/buildinfo` → valid JSON |
| 3. `make down` | PASS — containers and networks removed cleanly |
| 4. `make up` | PASS — stack recreated, both services healthy |
| 5. Confirm the UI returns | PASS — `GET /` → `200` again, same `deployment_id` as before, confirming persistent Postgres data was reused rather than re-initialized |

## Conclusion

Milestone M1 (trimmed) acceptance criteria are met: `coder` and `coder-db`
both report `healthy` via `make status`, and a full `make down && make up`
cycle preserves persistent data (verified via the stable `deployment_id`
sourced from the `coder_db_data` volume).
