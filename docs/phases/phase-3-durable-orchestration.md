# Phase 3 — Durable Orchestration & Capability Fabric

## Phase Objective

Prove that workflows survive worker failure, that fresh workspaces build fast via caching, and that agents/humans call controlled capability APIs instead of arbitrary shell access.

Milestones covered: **M6** (Embedded Simulation Workspace), **M7** (Artifact Registry + Build Cache), **M8** (Temporal Durable Workflow, including adding Temporal to compose), **M11** (MCP and Local Capability Fabric).

Depends on Phase 1's Coder/workspace mechanics (M3) and Session Plane (M4/M5) already being proven — M6 reuses the same workspace pattern with a heavier toolchain.

## Required Reading (mandatory, before starting Phase 3)

| Milestone | Tool | Required reading |
|---|---|---|
| M6 | QEMU user-mode emulation | https://www.qemu.org/docs/master/user/main.html |
| M7 | CNCF Distribution, sccache | https://distribution.github.io/distribution/about/deploying/, https://github.com/mozilla/sccache |
| M8 | Temporal | https://docs.temporal.io/best-practices, https://docs.temporal.io/best-practices/worker, https://docs.temporal.io/best-practices/error-handling, https://docs.temporal.io/self-hosted-guide/production-checklist |
| M8 | Reference implementation | [`tbrandenburg/temporal-sandbox`](https://github.com/tbrandenburg/temporal-sandbox) — a working local Temporal sandbox (Python SDK, Docker Compose, worker-restart e2e test) built by the same author; not a drop-in dependency (it runs the in-memory `temporal server start-dev`, not the Postgres-backed persistence/visibility this plan requires), but its bundle registry pattern, task-queue-mismatch/IPv4 gotchas, and worker-kill e2e test are directly reusable. See "Learnings from `temporal-sandbox`" under M8 below. |
| M11 | MCP | https://modelcontextprotocol.io/specification/draft/basic/security_best_practices |

---

## M6 — Embedded Simulation Workspace

### Objective

Prove that the same Coder/Docker model from Phase 1 M3 supports an embedded-style toolchain. Does **not** require physical hardware — use simulated tooling.

### Example

Create `examples/embedded-sim/`. Possible toolchain: `gcc`, `cmake`, `ninja`, `qemu-user` or a small emulator. **Caveat:** `qemu-user` only emulates userspace/syscalls for a cross-compiled binary against the target's libc — no MMIO/interrupts/peripherals/boot process. Good for "compile → run → check exit code/stdout," not a hardware simulator; for bare-metal firmware use `qemu-system` with a machine model instead. A simple example could compile a C application, execute tests, produce a firmware-like binary artifact, and run a simulated target:

```bash
make configure
make build
make test
make simulate
```

### Workspace Type

Create `embedded-linux` as a Docker workspace containing the full toolchain. Do not require host package installation.

### Toolchain Provenance

The buildchain should not just be "latest ubuntu + random apt installs." Use a `Dockerfile` with a pinned base, pinned tool versions, and a recorded image digest — pushed to the local OCI registry introduced in M7. This gives a workspace a reproducible identity: repo revision + Dev Container revision + toolchain image digest. If the build host sits behind a corporate/TLS-intercepting proxy, apply the same optional `CACERT`/BuildKit-secret pattern documented in Phase 1's M3 rather than inventing a second mechanism.

### Validation Milestone M6

Fresh `embedded-linux` workspace must successfully execute:

```bash
make -C examples/embedded-sim clean
make -C examples/embedded-sim build
make -C examples/embedded-sim test
make -C examples/embedded-sim simulate
```

### Manual E2E Test M6

Delete the workspace first, then `Coder → New Workspace → embedded-linux`. Verify a completely clean environment can produce the target artifact.

Record artifact filename, compiler version, image digest, test output, simulation output in `docs/milestone-reports/M6-embedded.md`.

---

## M7 — Artifact Registry + Build Cache

### Objective

For embedded development especially, fresh workspaces are painful without caching. This isn't a conceptual developer-facing layer, but a missing infrastructure capability under the Development Execution Plane that M6's reproducibility goal depends on for usable performance.

Add:

```text
Artifact / Cache Services
├── local OCI registry (CNCF Distribution, Apache-2.0)
├── BuildKit cache
├── sccache / ccache
└── persistent dependency caches
```

`cache/registry/` for the registry service, `cache/sccache/` for the compiler cache (start with a persistent local directory; a dedicated `sccache-storage` compose service is optional).

**Registry must not be open/unauthenticated.** CNCF Distribution's deployment guide requires TLS and ideally access control for a production-ready registry. Bind it only to the internal compose network with no host port published, or enable basic auth. If a healthcheck is added, note that an authenticated registry returns `401` from `/v2/`, not `200` — a naive `curl -f` check will misreport it as unhealthy.

**sccache cache-key gotcha:** cache keys include absolute paths by default, so the cold/warm comparison in the Validation below will silently fail to hit cache if the two fresh workspaces mount the project at different absolute paths. Set `SCCACHE_BASEDIRS` (or use an identical mount path, e.g. `/workspace`, across workspace instances).

### Validation Milestone M7

1. Build `examples/embedded-sim` from a fresh workspace (cold cache) and record the build time.
2. Build it again from a second fresh workspace (warm cache via registry/sccache) and record the build time.
3. Confirm the second build is measurably faster, with cache hits shown in `sccache --show-stats` (or equivalent).

### Manual E2E Test M7

1. Delete any existing registry/cache volumes to guarantee a cold start.
2. Time a fresh `embedded-linux` workspace build (M6's example).
3. Delete the workspace (but not the cache volumes) and create a new one.
4. Time the build again.
5. Compare timings and cache-hit statistics.

Record in `docs/milestone-reports/M7-cache.md`.

---

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

---

## M11 — MCP and Local Capability Fabric

### Objective

Allow humans and agents to query private capabilities without granting arbitrary shell access. Implement two simple services. **Both must follow the MCP spec's "Local MCP Server Compromise" guidance:** use `stdio` transport (spawned by the agent harness) wherever possible; if a service instead exposes HTTP, it must require a bearer token or bind to a Unix domain socket — never an open, unauthenticated TCP port.

### MCP Service 1 — Documentation

Tools: `search_docs(query)`, `get_architecture()`, `get_build_instructions()`. Populate from local Markdown documentation. Use `stdio` transport — no reason for this service to be network-reachable.

### MCP/HTTP Service 2 — Lab Simulator

Do not use physical hardware yet. Implement `list_devices()`, `reserve_device()`, `flash_device()`, `run_test()`, `get_logs()`, `release_device()` against simulated devices.

**Bind reservation tokens to the requesting caller.** Per the MCP spec's "State Handle Hijacking" guidance, `reserve_device()`'s returned reservation ID is a server-issued state handle that must be bound server-side to the authenticated caller — `run_test()`/`get_logs()`/`release_device()` must verify the caller matches the reservation owner, not accept the ID alone as authorization.

Example state:

```json
{ "device": "ecu-demo-01", "status": "available" }
```

### Validation Milestone M11

Agent (via the harness chosen in Phase 1 M9) should be able to answer: *"Which demo ECU is currently available, and what build command should I use?"* using the appropriate tool services.

### Manual E2E Test M11

Ask the agent to: query available simulated devices, reserve one, execute approved test operation, retrieve logs, release device. Verify through service logs that calls happened through defined APIs rather than arbitrary host shell commands.

Record in `docs/milestone-reports/M11-mcp.md`.

---

## Phase 3 Manual E2E Testing (performed by you, the agent)

You, as the agent, must personally execute every Manual E2E Test in this phase (M6, M7, M8, M11) end-to-end. For M6, delete and recreate the `embedded-linux` workspace yourself and produce the real artifact. For M7, actually time both a cold and a warm build yourself — do not estimate or assume cache benefit. For M8, actually kill and restart the worker container yourself and confirm the workflow resumes — do not accept a description of expected behavior in place of the real restart. For M11, drive the simulated device lifecycle (`reserve → run_test → get_logs → release`) yourself through the MCP tool calls, not a direct shell/API bypass. Capture command output, exit codes, and timestamps per the evidence standard (`docs/INITIAL.md` Section 3, Rule 2), and record results in `docs/milestone-reports/M6-embedded.md`, `M7-cache.md`, `M8-temporal.md`, and `M11-mcp.md` before considering Phase 3 complete.

---

## Phase 3 Documentation & Agent Instructions Update

Before Phase 3 is considered done, you, as the agent, must:

1. **Update project docs** — update `docs/architecture.md` and `docs/operations.md` to describe the added Temporal topology, the `embedded-linux` toolchain contents and image provenance, the artifact registry/cache setup, and the MCP tool surface (docs server + lab simulator) as actually implemented.
2. **Update `AGENTS.md`** at the repo root with:
   - **Guidelines** — any new binding rule discovered (e.g. Temporal worker restart timing, embedded toolchain image size limits on constrained hardware, cache-hit tuning, MCP tool-call error handling conventions).
   - **Agent Instructions** — how to start/inspect a Temporal workflow, how to open the `embedded-linux` workspace, how to check registry/cache status, and how the agent harness (`opencode`/`pi`) should call the MCP docs/lab-simulator tools instead of shelling out.
   - **Lessons Learned** — a dated entry (`## Phase 3 — <date>`) covering what broke, what surprised you, and what to avoid next time. Append; do not overwrite prior entries.

---

## Phase 3 Exit Criteria

- [ ] `embedded-linux` workspace builds, tests, and simulates the embedded example from a fresh workspace with no host package installation, with recorded image digest.
- [ ] A local OCI registry (auth-protected or internal-network-only) and sccache (with `SCCACHE_BASEDIRS` or a fixed mount path) are in place, and a warm-cache build is measurably faster than a cold-cache build.
- [ ] Temporal, Temporal-DB, Temporal-UI added to compose and healthy alongside Coder, with a shared Task Queue constant, explicit Activity timeouts, and idempotent Activities.
- [ ] A durable workflow completes correctly across a worker kill/restart (Durability Test 2).
- [ ] MCP docs + lab-simulator services respond only to defined tool calls (no arbitrary shell) over `stdio` or an authenticated/unix-socket transport, with reservation tokens bound to the requesting caller, verified via service logs.
- [ ] `docs/milestone-reports/M1-compose.md` (updated), `M6-embedded.md`, `M7-cache.md`, `M8-temporal.md`, `M11-mcp.md` are committed with command-level evidence.
- [ ] `docs/architecture.md` and `docs/operations.md` reflect the actual Phase 3 implementation.
- [ ] `AGENTS.md` has updated Guidelines, Agent Instructions, and a dated Phase 3 Lessons Learned entry.
