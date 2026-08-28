> Mandatory: read the overall plan in full before proceeding: doc/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## M1 (trimmed) — Compose Foundation: Coder only

### Objective

Prove that the Coder half of the platform can be brought up and down predictably. Temporal/Temporal-DB/Temporal-UI are **not** part of this phase — added in Phase 3, M8.

Initially include only:

```text
PostgreSQL (coder-db)
Coder
```

### Compose Requirements

Every service must have: pinned image version, explicit network, named volume if persistent, restart policy, health check where supported.

Create networks: `platform-control`, `platform-workspaces`. Do not use `network_mode: host`.

### Commands

```bash
make up
make down
make status
make logs
```

`make up` should ultimately execute something equivalent to `docker compose up -d` but hide implementation details from users.

### Validation Milestone M1 (trimmed)

```bash
make up
make status
```

Verify: `coder healthy`, `coder-db healthy`. Then `make down && make up` and verify persistent data remains valid.

### Manual E2E Test M1 (trimmed)

1. Start the stack.
2. Open Coder UI in a browser.
3. `make down`
4. `make up`
5. Confirm the UI returns.

Record in `docs/milestone-reports/M1-compose.md`: commands, screenshots/logs, container status, startup time, restart result.
