# M8 Temporal Durable Workflow — Milestone Report

Evidence captured for Phase 3 / Milestone M8 (Temporal Durable Workflow),
per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`docs/plan/plan.md` (M8 section).

- **Timestamp (UTC):** 2026-08-28T18:32Z
- **Environment:** local Docker Compose stack (`compose.yaml`), same host
  as M0-M7. `docker compose version v2.40.3-desktop.1`.
- **Images:** `temporalio/auto-setup:1.29.7` (server, SQL/Postgres
  persistence + visibility, no Elasticsearch), `temporalio/ui:2.53.3`,
  `postgres:16.10-alpine` (Temporal-supported major version 16, per
  `temporalio/docker-compose`'s own reference `.env`), and
  `devenv-cloud/temporal-worker:latest` (built from `temporal/Dockerfile`,
  `temporalio` Python SDK 1.32.0).

## What was built

- `compose.yaml` — four new services: `temporal-db` (Postgres, named
  volume `temporal_db_data`), `temporal` (`auto-setup`, SQL-based
  persistence + visibility only, no ES/OpenSearch dependency), `temporal-ui`
  (published on host port 8088), `temporal-worker` (runs the demo Worker,
  named volume `temporal_worker_state` for idempotency state). All four
  attached to `platform-control` only (no new dependency on
  `platform-workspaces`); pinned versions, explicit healthchecks,
  `restart: unless-stopped` (except `temporal-worker`'s dependency ordering
  via `depends_on: temporal: condition: service_healthy`), no
  `network_mode: host`.
- `temporal/` — new top-level directory:
  - `src/demo/config.py` — shared `TASK_QUEUE` constant
    (`demo-durable-workflow`) and env-injected `TEMPORAL_ADDRESS`/
    `TEMPORAL_NAMESPACE`, imported by both starter and worker (the "Shared
    Task Queue name constant" and "env-injected connection config" patterns
    from `tbrandenburg/temporal-sandbox`).
  - `src/demo/workflows.py` — `DemoDurableWorkflow`: `prepare_build` →
    `workflow.sleep(30s)` → `verify_build`. Explicit
    `start_to_close_timeout=30s` on both Activities (hard SDK requirement).
    `prepare_build` uses a `RetryPolicy` tuned for the *intermittent*
    category (`backoff_coefficient=2.0`, `maximum_interval=10s`,
    `maximum_attempts=5`); `verify_build` uses `maximum_attempts=3`.
  - `src/demo/activities.py` — `prepare_build`/`verify_build`, both keyed
    by Workflow Run ID + Activity ID for idempotency, state persisted to a
    JSON file on the `temporal_worker_state` volume (survives container
    kill/recreate, not just in-process retries). `prepare_build` raises a
    **non-retryable** `ApplicationError` on empty `build_id` — the
    deliberately-exercised **permanent**-failure category (see "Error
    handling categorization" below); no code exercises the *transient*
    category since the default Retry Policy already covers it per the
    step's own guidance.
  - `src/demo/worker.py` — installs `SIGINT`/`SIGTERM` handlers that cancel
    the running worker task (`graceful_shutdown_timeout=5s`) rather than a
    bare process exit, for the *normal* stop path.
  - `src/demo/starter.py` — CLI: `python -m demo.starter [--build-id ID]
    [--workflow-id ID] [--wait]`, prints `workflow_id=... run_id=...`.
  - `pyproject.toml` + `uv.lock` — `temporalio>=1.32.0,<2`, `uv sync
    --frozen` reproducible install.
  - `Dockerfile` — multi-stage (`builder` runs `uv sync --frozen --no-dev
    --no-install-project`, only `.venv` + `src` copied into the `runtime`
    stage), non-root `demo` user (uid/gid 1000).
- `Makefile` — `temporal-worker-build` (builds the image) and
  `temporal-demo-start` (starts one execution via a throwaway container on
  `platform-control`, prints workflow/run ID).
- `.env` / `.env.example` — `TEMPORAL_VERSION`, `TEMPORAL_UI_VERSION`,
  `TEMPORAL_GRPC_PORT`, `TEMPORAL_UI_PORT`, `TEMPORAL_PG_*`.

## Pitfall found and fixed: `BIND_ON_IP` vs `TEMPORAL_ADDRESS`

`temporalio/auto-setup`'s entrypoint binds the frontend/history/matching/
worker gRPC services to `BIND_ON_IP` (defaulting to this container's own
hostname-resolved IP if unset) — **not** to the host part of
`TEMPORAL_ADDRESS`, which only sets the address the `temporal` CLI itself
defaults to. Left unset, the server bound only to its own container IP
(confirmed via `netstat` inside the running container), so a
`127.0.0.1`-targeted healthcheck (the M8 step's own "always use 127.0.0.1,
never bare localhost" guidance, correct for `temporal server start-dev` but
not for this image) failed even though the server was healthy. Fixed by
setting `BIND_ON_IP=0.0.0.0` explicitly, so the server listens on every
interface: reachable both as `temporal:7233` (other compose services, via
Docker DNS) and as `127.0.0.1:7233` (this container's own CLI invocations
and healthcheck).

A second, separate issue: the `temporal` CLI's own gRPC DNS resolver, when
invoked *from inside the `temporal` container itself* against the bare
service hostname (`temporal:7233`), reliably hung for the full ~8s dial
timeout and failed with `context deadline exceeded` — even after the
`BIND_ON_IP` fix, even though `getent hosts temporal` resolved instantly and
a plain TCP connection to the same IP worked immediately. This is *not* a
general Docker-DNS-from-any-container issue: a throwaway `curlimages/curl`
container on the same `platform-control` network resolved and connected to
`temporal:7233` instantly, and the actual `temporal-worker` Python/gRPC
client connects to `temporal:7233` with no delay (confirmed in its logs).
It appears specific to the `temporal` CLI's resolver running inside that
same container. Worked around by setting this container's own
`TEMPORAL_ADDRESS`/`TEMPORAL_CLI_ADDRESS` to `127.0.0.1:7233` (used only for
`auto-setup.sh`'s internal `temporal operator cluster health` /
`register_default_namespace` calls and this compose service's own
healthcheck) — other services keep their own independent
`TEMPORAL_ADDRESS=temporal:7233` and are unaffected.

## Validation Milestone M8 — evidence

```
$ make up
$ make status
NAME                  ...  STATUS
coder                 ...  Up ... (healthy)
coder-db              ...  Up ... (healthy)
temporal              ...  Up ... (healthy)
temporal-db           ...  Up ... (healthy)
temporal-ui           ...  Up ... (healthy)
temporal-worker       ...  Up ...
```
(`temporal-worker` has no explicit healthcheck of its own — a long-running
Python process with no HTTP endpoint to probe — its correct operation is
evidenced directly by workflow completion below.)

```
$ make down && make up
```
Confirmed named volumes (`coder_db_data`, `coder_home`, `temporal_db_data`,
`temporal_worker_state`, `registry_data`) survive `down` (checked via
`docker volume ls`), and after `up`: `curl -sf http://localhost:7080/healthz`
→ `OK` (Coder), and `temporal workflow show -w
demo-durable-workflow-8f6f06dc` still returns the `COMPLETED` result from
*before* the `down`/`up` cycle — Temporal persistence and Coder persistence
both proven, `workflow list` shows all 3 prior workflow executions
retained.

### Stop/start worker mid-timer (the step's own Validation M8 test)

```
$ make temporal-demo-start
workflow_id=demo-durable-workflow-8f6f06dc run_id=01a049a1-8f6f-701c-a5a6-a88ff2219dee

18:28:54Z  docker compose stop temporal-worker      (during the 30s TimerStarted window)
18:29:07Z  workflow still WORKFLOW_EXECUTION_STATUS_RUNNING (worker down, timer live in Temporal-DB)
18:29:07Z  docker compose start temporal-worker
18:29:13Z  workflow WORKFLOW_EXECUTION_STATUS_COMPLETED
```
Result: `"prepared:demo-3b734206 -> verified:prepared:demo-3b734206"`.
Event history confirms `TimerStarted` (18:28:40Z) → `TimerFired`
(18:29:10Z, ~30s later, unaffected by the worker being down 18:28:54Z-
18:29:07Z) → `verify_build` Activity → `WorkflowExecutionCompleted`.

## Manual E2E Test M8 — evidence

Per plan requirement (Rule: agent must personally execute this, not
describe expected behavior): both failure modes tested independently.

1. `make temporal-demo-start` → `workflow_id=demo-durable-workflow-7ee3ced8
   run_id=01a049a2-3e06-7d39-9204-036c63aa31f4`.
2. **Step 2 — worker absence:** `18:29:28Z docker compose kill
   temporal-worker` (SIGKILL, not a graceful stop).
3. **Step 3 — server-process restart:** `18:29:39Z docker compose restart
   temporal`; confirmed `Up ... (healthy)` again within ~19s.
4. **Step 4:** `18:30:04Z docker compose start temporal-worker`. Worker
   logs show it starting, connecting to `temporal:7233`, no manual
   reconfiguration needed.
5. **Step 5 — verify resumption:** polled `workflow describe`, observed
   `WORKFLOW_EXECUTION_STATUS_COMPLETED` at `18:30:18Z`. Event history:
   `TimerStarted` 18:29:24Z → `TimerFired` 18:29:54Z (unaffected by either
   the worker kill at 18:29:28Z or the Temporal server restart at
   18:29:39Z-18:29:58Z, both of which happened *during* the timer) →
   `WorkflowTaskTimedOut` once (expected transient effect of the server
   restart racing a workflow task, self-healed on the next attempt,
   *before* the worker even came back at 18:30:04Z) → `verify_build`
   Activity → `WorkflowExecutionCompleted`. Result:
   `"prepared:demo-766ca155 -> verified:prepared:demo-766ca155"`.
6. **Step 6 — Temporal UI history:** screenshot at
   `.playwright-mcp/m8-workflow-history.png` (Timeline view of
   `demo-durable-workflow-7ee3ced8`, namespace `default`).

**Did the process survive worker failure without manual state
reconstruction? YES.** Both the ungraceful `kill` of the worker and the
independent `restart` of the Temporal server itself were absorbed without
any manual intervention beyond bringing the two processes back up — no
workflow state was reconstructed by hand; it lived in Temporal-DB
throughout.

## Error handling categorization — which category was exercised

Per the step's explicit requirement that "a demo that never throws a
permanent failure has not actually proven the non-retryable path works":

- **Transient** — not separately exercised; relies on the SDK's default
  Retry Policy, per the step's own guidance that no code change is needed
  for this category.
- **Intermittent** — `prepare_build`'s `RetryPolicy` in
  `workflows.py` tunes `backoff_coefficient=2.0`/`maximum_interval=10s`
  instead of the SDK default, so a rate-limited dependency would be
  spaced out rather than hammered (not separately triggered in this run,
  since `prepare_build` never fails transiently in the demo).
- **Permanent — deliberately exercised.** Ran
  `python -m demo.starter --build-id "" --wait` (empty `build_id`) against
  the running stack: workflow `demo-durable-workflow-7940a11c` failed with
  `WorkflowFailureError` / `ActivityError` wrapping the non-retryable
  `ApplicationError` raised in `prepare_build`. Event history confirms
  exactly **one** `ActivityTaskStarted` → `ActivityTaskFailed` →
  `WorkflowExecutionFailed` — zero retries, proving `non_retryable=True`
  took effect rather than silently being discarded.
- **Saga pattern** — out of scope for this two-Activity demo (no
  compensating action needed since neither Activity has an external
  side effect requiring rollback); noted here as considered and
  deliberately deferred, per the step's guidance.

## `docs/milestone-reports/M1-compose.md` update

See that file's own "M8 addition" section, appended below its original M1
content, documenting the four new services and the `down`/`up` persistence
re-verification performed above.
