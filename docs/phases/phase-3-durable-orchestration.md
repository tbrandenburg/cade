# Phase 3 — Durable Orchestration & Capability Fabric

## Phase Objective

Prove that workflows survive worker failure, and that agents/humans call controlled capability APIs instead of arbitrary shell access.

Milestones covered: **M1 (remainder)** — add Temporal to the compose stack, **M5** (Temporal Durable Workflow), **M4** (Embedded Simulation Workspace), **M8** (MCP and Local Capability Fabric).

Depends on Phase 1's Coder/workspace mechanics (M3) already being proven — M4 reuses the same workspace pattern with a heavier toolchain.

---

## M1 (remainder) — Add Temporal to Compose

Add to the compose stack already running Coder + Coder-DB from Phase 1:

```text
Temporal
Temporal-DB
Temporal UI
```

Apply the same Compose Requirements as Phase 1 (pinned versions, explicit networks, named volumes, restart policy, health checks; no `network_mode: host`).

### Validation

```bash
make up
make status
```

Verify:

```text
coder          healthy
coder-db       healthy
temporal       healthy
temporal-db    healthy
temporal-ui    healthy
```

Then `make down && make up` and verify all persistent data (Coder + Temporal) remains valid.

Update `docs/milestone-reports/M1-compose.md` with the Temporal addition.

---

## M5 — Temporal Durable Workflow

### Objective

Prove durable orchestration independently of GitHub agents. Implement a deliberately simple workflow:

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

### Validation Milestone M5

Start workflow. During the timer:

```bash
docker compose stop temporal-worker
```

Wait several seconds, then:

```bash
docker compose start temporal-worker
```

Expected: workflow continues, workflow completes, workflow state not lost.

### Manual E2E Test M5

1. Start the durable demo.
2. Kill worker container (`docker compose kill temporal-worker`).
3. Restart the Temporal server component only (`docker compose restart temporal`) — do not reboot the host for this step.
4. Restart worker (`docker compose start temporal-worker`).
5. Verify workflow resumes.
6. Inspect Temporal UI history.

Record screenshots/logs and workflow ID in `docs/milestone-reports/M5-temporal.md`, explicitly answering: *"Did the process survive worker failure without manual state reconstruction?"* Expected: YES.

---

## M4 — Embedded Simulation Workspace

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

### Validation Milestone M4

Fresh `embedded-linux` workspace must successfully execute:

```bash
make -C examples/embedded-sim clean
make -C examples/embedded-sim build
make -C examples/embedded-sim test
make -C examples/embedded-sim simulate
```

### Manual E2E Test M4

Delete the workspace first, then `Coder → New Workspace → embedded-linux`. Verify a completely clean environment can produce the target artifact.

Record artifact filename, compiler version, test output, simulation output in `docs/milestone-reports/M4-embedded.md`.

---

## M8 — MCP and Local Capability Fabric

### Objective

Allow humans and agents to query private capabilities without granting arbitrary shell access. Implement two simple services.

### MCP Service 1 — Documentation

Tools: `search_docs(query)`, `get_architecture()`, `get_build_instructions()`. Populate from local Markdown documentation.

### MCP/HTTP Service 2 — Lab Simulator

Do not use physical hardware yet. Implement `list_devices()`, `reserve_device()`, `flash_device()`, `run_test()`, `get_logs()`, `release_device()` against simulated devices. Example state:

```json
{ "device": "ecu-demo-01", "status": "available" }
```

### Validation Milestone M8

Agent (via the harness chosen in Phase 1 M6) should be able to answer: *"Which demo ECU is currently available, and what build command should I use?"* using the appropriate tool services.

### Manual E2E Test M8

Ask the agent to: query available simulated devices, reserve one, execute approved test operation, retrieve logs, release device. Verify through service logs that calls happened through defined APIs rather than arbitrary host shell commands.

Record in `docs/milestone-reports/M8-mcp.md`.

---

## Phase 3 Manual E2E Testing (performed by you, the agent)

You, as the agent, must personally execute every Manual E2E Test in this phase (M5, M4, M8) end-to-end. For M5, actually kill and restart the worker container yourself and confirm the workflow resumes — do not accept a description of expected behavior in place of the real restart. For M4, delete and recreate the `embedded-linux` workspace yourself and produce the real artifact. For M8, drive the simulated device lifecycle (`reserve → run_test → get_logs → release`) yourself through the MCP tool calls, not a direct shell/API bypass. Capture command output, exit codes, and timestamps per the evidence standard (`docs/INITIAL.md` Section 3, Rule 2), and record results in `docs/milestone-reports/M5-temporal.md`, `M4-embedded.md`, and `M8-mcp.md` before considering Phase 3 complete.

---

## Phase 3 Documentation & Agent Instructions Update

Before Phase 3 is considered done, you, as the agent, must:

1. **Update project docs** — update `docs/architecture.md` and `docs/operations.md` to describe the added Temporal topology, the `embedded-linux` toolchain contents, and the MCP tool surface (docs server + lab simulator) as actually implemented.
2. **Update `AGENTS.md`** at the repo root with:
   - **Guidelines** — any new binding rule discovered (e.g. Temporal worker restart timing, embedded toolchain image size limits on constrained hardware, MCP tool-call error handling conventions).
   - **Agent Instructions** — how to start/inspect a Temporal workflow, how to open the `embedded-linux` workspace, and how the agent harness (`opencode`/`pi`) should call the MCP docs/lab-simulator tools instead of shelling out.
   - **Lessons Learned** — a dated entry (`## Phase 3 — <date>`) covering what broke, what surprised you, and what to avoid next time. Append; do not overwrite prior entries.

---

## Phase 3 Exit Criteria

- [ ] Temporal, Temporal-DB, Temporal-UI added to compose and healthy alongside Coder.
- [ ] A durable workflow completes correctly across a worker kill/restart.
- [ ] `embedded-linux` workspace builds, tests, and simulates the embedded example from a fresh workspace with no host package installation.
- [ ] MCP docs + lab-simulator services respond only to defined tool calls (no arbitrary shell), verified via service logs.
- [ ] `docs/milestone-reports/M1-compose.md` (updated), `M5-temporal.md`, `M4-embedded.md`, `M8-mcp.md` are committed with command-level evidence.
- [ ] `docs/architecture.md` and `docs/operations.md` reflect the actual Phase 3 implementation.
- [ ] `AGENTS.md` has updated Guidelines, Agent Instructions, and a dated Phase 3 Lessons Learned entry.
