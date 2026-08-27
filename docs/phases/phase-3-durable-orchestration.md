# Phase 3 — Durable Orchestration & Capability Fabric

## Phase Objective

Prove that workflows survive worker failure, that fresh workspaces build fast via caching, and that agents/humans call controlled capability APIs instead of arbitrary shell access.

Milestones covered: **M6** (Embedded Simulation Workspace), **M7** (Artifact Registry + Build Cache), **M8** (Temporal Durable Workflow, including adding Temporal to compose), **M11** (MCP and Local Capability Fabric).

Depends on Phase 1's Coder/workspace mechanics (M3) and Session Plane (M4/M5) already being proven — M6 reuses the same workspace pattern with a heavier toolchain.

---

## M6 — Embedded Simulation Workspace

### Objective

Prove that the same Coder/Docker model from Phase 1 M3 supports an embedded-style toolchain. Does **not** require physical hardware — use simulated tooling.

### Example

Create `examples/embedded-sim/`. Possible toolchain: `gcc`, `cmake`, `ninja`, `qemu-user` or a small emulator. A simple example could compile a C application, execute tests, produce a firmware-like binary artifact, and run a simulated target:

```bash
make configure
make build
make test
make simulate
```

### Workspace Type

Create `embedded-linux` as a Docker workspace containing the full toolchain. Do not require host package installation.

### Toolchain Provenance

The buildchain should not just be "latest ubuntu + random apt installs." Use a `Dockerfile` with a pinned base, pinned tool versions, and a recorded image digest — pushed to the local OCI registry introduced in M7. This gives a workspace a reproducible identity: repo revision + Dev Container revision + toolchain image digest.

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
Temporal-DB
Temporal UI
```

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

### Manual E2E Test M8

1. Start the durable demo.
2. Kill worker container (`docker compose kill temporal-worker`).
3. Restart the Temporal server component only (`docker compose restart temporal`) — do not reboot the host for this step.
4. Restart worker (`docker compose start temporal-worker`).
5. Verify workflow resumes.
6. Inspect Temporal UI history.

Record screenshots/logs and workflow ID in `docs/milestone-reports/M8-temporal.md`, explicitly answering: *"Did the process survive worker failure without manual state reconstruction?"* Expected: YES.

---

## M11 — MCP and Local Capability Fabric

### Objective

Allow humans and agents to query private capabilities without granting arbitrary shell access. Implement two simple services.

### MCP Service 1 — Documentation

Tools: `search_docs(query)`, `get_architecture()`, `get_build_instructions()`. Populate from local Markdown documentation.

### MCP/HTTP Service 2 — Lab Simulator

Do not use physical hardware yet. Implement `list_devices()`, `reserve_device()`, `flash_device()`, `run_test()`, `get_logs()`, `release_device()` against simulated devices. Example state:

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
- [ ] A local OCI registry and sccache are in place, and a warm-cache build is measurably faster than a cold-cache build.
- [ ] Temporal, Temporal-DB, Temporal-UI added to compose and healthy alongside Coder.
- [ ] A durable workflow completes correctly across a worker kill/restart (Durability Test 2).
- [ ] MCP docs + lab-simulator services respond only to defined tool calls (no arbitrary shell), verified via service logs.
- [ ] `docs/milestone-reports/M1-compose.md` (updated), `M6-embedded.md`, `M7-cache.md`, `M8-temporal.md`, `M11-mcp.md` are committed with command-level evidence.
- [ ] `docs/architecture.md` and `docs/operations.md` reflect the actual Phase 3 implementation.
- [ ] `AGENTS.md` has updated Guidelines, Agent Instructions, and a dated Phase 3 Lessons Learned entry.
