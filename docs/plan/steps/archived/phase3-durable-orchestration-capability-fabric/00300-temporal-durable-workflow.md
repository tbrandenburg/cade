> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 3 — Durable Orchestration & Capability Fabric

## M8 — Temporal Durable Workflow

### Add Temporal to Compose

Add to the compose stack already running Coder + Coder-DB since Phase 1:

```text
Temporal
Temporal-DB (PostgreSQL, pin to a Temporal-supported major version)
Temporal UI
```

**Use the SQL-based visibility variant (no Elasticsearch/OpenSearch)** — Temporal's own headline reference compose additionally requires Elasticsearch for visibility by default; this plan deliberately uses Postgres for both persistence and visibility instead, per `temporalio/samples-server`'s `docker-compose-postgres.yml` reference (the older `temporalio/docker-compose` repo is archived).

Apply the same Compose Requirements as Phase 1 (pinned versions, explicit networks, named volumes, restart policy, health checks; no `network_mode: host`).

Verify:

```bash
make up
make status
```

```text
coder          healthy
coder-db       healthy
temporal       healthy
temporal-db    healthy
temporal-ui    healthy
```

Then `make down && make up` and verify all persistent data (Coder + Temporal) remains valid. Update `docs/milestone-reports/M1-compose.md` with the Temporal addition.

### Objective

Prove durable orchestration independently of GitHub agents, and independently of the session/workspace durability proven in Phase 1 (Rule 7, `docs/INITIAL.md` Section 3). Implement a deliberately simple workflow:

```text
start → activity A → wait 30 seconds → activity B → finish
```

**Three requirements from Temporal's own best-practices docs, not optional:**

- **Shared Task Queue name constant.** A Client/Worker Task Queue name mismatch does not error — the workflow just silently never gets picked up. Define the name once (e.g. `demo-durable-workflow`) and import it in both the starter and the worker.
- **Explicit Activity timeouts.** Temporal SDKs require at least one timeout (e.g. `StartToCloseTimeout: 30s`) per Activity or it cannot be scheduled — this is a hard requirement, not a style preference. Set it on both `prepare_build` and `verify_build`.
- **Activity idempotency.** Activities may execute more than once due to retries (e.g. a worker crash after completing but before acknowledging). Per the official [error-handling best practices](https://docs.temporal.io/best-practices/error-handling#design-activities-for-idempotence), key `prepare_build`/`verify_build` by **Workflow Run ID combined with Activity ID** (not Run ID alone) — that combination is what stays consistent across retries of the *same* Activity while remaining unique across Workflow Executions. This is also what makes the worker-kill test below a meaningful proof rather than a lucky no-op.

### Learnings from `temporal-sandbox` (reuse, don't rediscover)

[`tbrandenburg/temporal-sandbox`](https://github.com/tbrandenburg/temporal-sandbox) is a separate,
already-working local Temporal sandbox (Python SDK, same author). It targets the in-memory
`temporal server start-dev` rather than this plan's Postgres-backed persistence/visibility stack,
so it cannot be added as a Compose dependency as-is — but its patterns and hard-won gotchas
transfer directly to M8's implementation. This is not limited to its `AGENTS.md` lessons-learned
log; the following are patterns actually implemented in its source (`src/sandbox/`, `Dockerfile`,
`docker-compose.yml`), cross-checked against the official
[Worker deployment/performance](https://docs.temporal.io/best-practices/worker) and
[error handling](https://docs.temporal.io/best-practices/error-handling) best-practices docs where
the two overlap.

- **Bundle registry instead of ad-hoc wiring.** A single `Bundle` dataclass
  (`name`, `workflows`, `activities`, `task_queue` defaulting to `name`, exposed via an
  `effective_task_queue` property) registered in a module-level `REGISTRY` dict, consumed by one
  shared `worker.py`/`starter.py` entrypoint pair (`src/sandbox/registry.py`,
  `src/sandbox/worker.py`). This is exactly the "Shared Task Queue name constant" requirement
  above, generalized: the task queue is derived once from the bundle name and imported by both
  starter and worker, so a name mismatch (which silently no-ops rather than erroring, per the
  official worker best-practices doc's own warning: *"a mismatch between the Client and Worker Task
  Queue names does not result in an error... it creates two different Task Queues, and the Worker
  never receives Tasks"*) becomes structurally impossible instead of a documentation reminder.
  Worth adopting verbatim for `demo-durable-workflow` even with only one bundle today — it costs
  nothing and pays off the moment a second workflow is added, and directly implements the official
  doc's "Separate Task Queues logically" guidance (one Task Queue per distinct workload).
- **Env-injected connection config, read once at import.** `src/sandbox/config.py` reads
  `TEMPORAL_ADDRESS`/`TEMPORAL_NAMESPACE`/`SANDBOX_BUNDLES` from the environment with sane
  localhost defaults, and both `worker.py`/`starter.py` import it rather than hardcoding values.
  This matches the official doc's "Package and configure Workers for flexibility" guidance almost
  verbatim: *"Inject all required parameters for connecting to Temporal Cloud or a self-hosted
  Temporal Service at runtime via environment variables"*. Apply the same pattern to the M8
  worker/starter rather than hardcoding `localhost:7233` anywhere.
- **Graceful shutdown, not a bare process kill, on the happy path.** `worker.py`'s `run_worker()`
  passes `graceful_shutdown_timeout=timedelta(seconds=5)` to the `Worker` constructor and installs
  `SIGINT`/`SIGTERM` handlers that cancel the running `asyncio.gather(...)` rather than exiting
  immediately. This directly implements the official doc's "Manage scale-down safely" guidance —
  *"verify that it does not have too many active Tasks... shutting it down could trigger expensive
  retries or timeouts... use Graceful Shutdowns to allow the Worker to complete its current
  Tasks"*. M8's worker should adopt the same pattern for its normal stop path; the **deliberate**
  hard-kill (`docker kill`, next bullet) stays reserved for proving durability, not for routine
  shutdown.
- **Multi-stage Dockerfile, non-root runtime user, lockfile-pinned deps.** The sandbox's
  `Dockerfile` builds with `uv sync --frozen --no-dev` in a `builder` stage (dev/test dependencies
  never reach the runtime image) and copies only the resulting `.venv` into a slim `runtime` stage
  running as a non-root `sandbox` user (`useradd --uid 1000`). This mirrors the shape (if not the
  exact toolchain) of the official reference app's Dockerfile pattern — multi-stage build, minimal
  final image, no build tooling in the runtime layer — and should be the template for M8's worker
  image rather than a single-stage `pip install` image.
- **`--address 127.0.0.1:7233`, never bare `localhost`.** On hosts where `localhost` resolves to
  `::1` (IPv6) first, the Temporal dev/server binds IPv4 only, producing a connection failure that
  looks like "server isn't running" when it's actually a resolution quirk. Apply this to every
  `temporal` CLI invocation, Makefile target, and Compose healthcheck in this plan's stack, e.g.:
  ```yaml
  healthcheck:
    test: ["CMD", "temporal", "--address", "127.0.0.1:7233", "operator", "namespace", "describe", "default"]
    interval: 5s
    timeout: 5s
    retries: 10
    start_period: 10s
  ```
- **Kill the worker container, don't just stop it, for a real durability proof.** `temporal-sandbox`'s
  `tests/e2e/test_worker_restart.py` uses `docker kill <worker-container>` (SIGKILL) mid-timer, then
  `docker compose up -d <worker-service>` to bring it back, then polls
  `temporal workflow describe -o json` until `WORKFLOW_EXECUTION_STATUS_COMPLETED`. `docker compose
  stop`/`start` (as M8's own Validation steps use) is a gentler SIGTERM-based shutdown; prefer `kill`
  at least once during the Manual E2E Test to rule out "the worker gracefully finished the activity
  before dying" as a false-positive explanation for durability.
- **A 10-second workflow-level sleep, not a real-time wall-clock trap.** `SleepGreetWorkflow` uses
  `workflow.sleep(timedelta(seconds=10))` — long enough for a human to `docker kill` mid-sleep,
  short enough not to slow down integration tests (which use `start_time_skipping()` and skip it
  instantly). M8's 30-second timer should follow the same reasoning: pick the shortest duration that
  reliably gives a human/script time to kill and restart the worker container.
- **Explicit `start_to_close_timeout` on every activity call, no exceptions** — confirmed the hard
  way: Temporal's Python SDK will not schedule an activity without one. `temporal-sandbox` sets it
  on every single-activity workflow, reinforcing the "not optional" framing already in this doc.

### Error handling: apply the official categorization to `prepare_build`/`verify_build`

`temporal-sandbox`'s demo workflows are simple enough not to need this, but M8's own
[best-practices/error-handling](https://docs.temporal.io/best-practices/error-handling) required
reading defines a categorization that `prepare_build`/`verify_build` should apply deliberately
rather than relying on Temporal's default Retry Policy alone:

- **Transient** (e.g. a one-off network blip) — the default Retry Policy already handles this;
  no code change needed.
- **Intermittent** (e.g. a rate-limited dependency) — tune `backoffCoefficient`/`maximumInterval`
  on the Retry Policy rather than accepting the SDK default, so retries space out instead of
  hammering the failing dependency.
- **Permanent** (e.g. malformed input to `prepare_build`) — mark the Application Failure
  **non-retryable** so it fails fast instead of burning retries that can never succeed. When
  wrapping such an error for additional context, wrap it in another Application Failure with the
  same `non_retryable` flag — wrapping it in a generic language exception silently discards the
  flag and the Activity retries anyway (per the doc's "outermost error type determines
  retryability" rule).

Record in `M8-temporal.md` which category (if any) was deliberately exercised — a demo that never
throws a permanent failure has not actually proven the non-retryable path works. If a future
milestone chains additional Activities after `verify_build`, the same required reading's
[Saga pattern](https://docs.temporal.io/best-practices/error-handling#implement-compensation-with-the-saga-pattern)
guidance applies (compensating action per step, run in reverse order on failure) — out of scope
for M8's two-Activity demo, but worth a one-line note in the milestone report if it's considered
and deliberately deferred.


### Required Demonstration

The workflow must survive worker failure:

```text
Temporal
   │
   ├─ Activity: prepare_build
   │
   ├─ Timer: 30 seconds
   │
   └─ Activity: verify_build
```

### Validation Milestone M8

Start workflow. During the timer:

```bash
docker compose stop temporal-worker
```

Wait several seconds, then:

```bash
docker compose start temporal-worker
```

Expected: workflow continues, workflow completes, workflow state not lost.

**Why this is safe:** the Timer is server-side state in the workflow's Event History (Temporal-DB), not worker memory — killing the worker during the timer doesn't affect it, as long as the Temporal Server itself stays up.

### Manual E2E Test M8

1. Start the durable demo.
2. Kill worker container (`docker compose kill temporal-worker`).
3. Restart the Temporal server component only (`docker compose restart temporal`) — do not reboot the host for this step.
4. Restart worker (`docker compose start temporal-worker`).
5. Verify workflow resumes.
6. Inspect Temporal UI history.

**Note:** steps 2 and 3 test two different failure modes — worker absence (step 2) vs. server-process restart (step 3). Both should succeed because state lives in Temporal-DB, not in either process's memory; report on both independently rather than as one combined test.

Record screenshots/logs and workflow ID in `docs/milestone-reports/M8-temporal.md`, explicitly answering: *"Did the process survive worker failure without manual state reconstruction?"* Expected: YES.

