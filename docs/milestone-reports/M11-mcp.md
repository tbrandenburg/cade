# M11 MCP and Local Capability Fabric — Milestone Report

Evidence captured for Phase 3 / Milestone M11 (MCP and Local Capability
Fabric), per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`docs/plan/plan.md` (M11 section).

- **Timestamp (UTC):** 2026-08-28T18:59:09Z
- **Environment:** local Docker Compose stack (`docker compose ps` — see
  below), `mcp` Python SDK `2.1.1` (`mcp.server.mcpserver.MCPServer`),
  harness: `opencode` (`opencode/big-pickle`, zero-config — the default
  harness selected in M9 for agent-driven MCP calls).

## What was built

- `mcp/docs-server/` — **MCP Service 1 (Documentation)**. `stdio` transport
  only (no reason for this read-only lookup service to be
  network-reachable, per the step's own guidance). Tools: `search_docs(query)`
  (case-insensitive substring search across every `docs/**/*.md` file,
  returns file/line/text), `get_architecture()` (full contents of
  `docs/ARCHITECTURE.md`), `get_build_instructions()` (README quickstart +
  parsed `Makefile` target list). Runs via `uv run python -m
  docs_server.server`, `cwd=mcp/docs-server`.
- `mcp/lab-sim/` — **MCP/HTTP Service 2 (Lab Simulator)**. `streamable-http`
  transport, mounted at `/mcp`. Tools: `list_devices`, `reserve_device`,
  `flash_device`, `run_test`, `get_logs`, `release_device` against three
  simulated devices (`devices.py`: `ecu-demo-01`, `ecu-demo-02`,
  `bms-demo-01` — no physical hardware). `auth.py` + `server.py`'s
  `BearerAuthMiddleware` require `Authorization: Bearer <token>` on every
  request (401 otherwise), resolved against `LAB_SIM_TOKENS`
  (`caller_id:token` pairs). Every tool re-resolves the caller from the same
  header and passes it into `LabSimulator`, which binds the
  `reserve_device()`-issued `reservation_id` to that caller —
  `flash_device`/`run_test`/`get_logs`/`release_device` raise
  `ReservationOwnershipError` (surfaced as a tool error) if a different
  caller presents a valid token but someone else's reservation ID. This is
  the concrete implementation of the step's "State Handle Hijacking" and
  "Local MCP Server Compromise" requirements.
- `mcp/lab-sim/Dockerfile` — multi-stage `uv`-managed build, non-root
  runtime user, mirrors `temporal/Dockerfile`'s pattern (M8).
  `mcp/lab-sim/healthcheck.py` — a bare (unauthenticated) request is
  *expected* to 401; that counts as healthy (mirrors the `registry`
  service's 401-is-healthy healthcheck convention from M7).
- `compose.yaml` — new `lab-sim` service on `platform-workspaces`, host port
  bound to `127.0.0.1:${LAB_SIM_PORT:-8300}` only (defense in depth on top
  of the bearer-token requirement — the agent harness runs directly on this
  host today, not inside a workspace container on `platform-workspaces`).
- `.env.example` — documents `LAB_SIM_PORT` / `LAB_SIM_TOKENS`.
- `opencode.jsonc` (repo root) — wires both services into `opencode`:
  `devenv-docs` (`type: local`, spawns the stdio server) and
  `devenv-lab-sim` (`type: remote`, `oauth: false`, static bearer header via
  `{env:LAB_SIM_AGENT_TOKEN}`).

## Validation Milestone M11

*"Which demo ECU is currently available, and what build command should I use?"*

```
$ LAB_SIM_AGENT_TOKEN="tok-aaa" opencode run --model opencode/big-pickle \
    "Use the devenv-lab-sim MCP tools to list available simulated devices \
     and tell me which one is available. Also use devenv-docs to get the \
     build instructions summary in one sentence. Be brief."

⚙ devenv-lab-sim_list_devices Unknown
⚙ devenv-docs_get_build_instructions Unknown
Available devices: `ecu-demo-01` and `ecu-demo-02` are **available**;
`bms-demo-01` is reserved.

Build instructions: `make doctor` → `make up` → `make coder-workspace-build`
starts the Postgres+Coder control plane and runs the platform lifecycle via
`make` targets at the repo root.
```

Both MCP servers resolved and called correctly, no manual tool wiring
needed beyond `opencode.jsonc`.

## Manual E2E Test M11

Full simulated-device lifecycle (`reserve → flash → run_test → get_logs →
release`), driven **by the agent itself** through the MCP tool calls (not a
direct shell/API bypass):

```
$ LAB_SIM_AGENT_TOKEN="tok-aaa" opencode run --model opencode/big-pickle \
    "Using only the devenv-lab-sim MCP tools (do not use shell/bash tools): \
     1) list devices and pick an available one, 2) reserve it, 3) flash it, \
     4) run the approved test operation, 5) retrieve the logs, 6) release \
     the device. Report the reservation id, test result, and final log lines."

⚙ devenv-lab-sim_list_devices Unknown
⚙ devenv-lab-sim_reserve_device {"device_id":"ecu-demo-01"}
⚙ devenv-lab-sim_flash_device {"reservation_id":"7cd2a66dc54d9a9d"}
⚙ devenv-lab-sim_run_test {"reservation_id":"7cd2a66dc54d9a9d"}
⚙ devenv-lab-sim_get_logs {"reservation_id":"7cd2a66dc54d9a9d"}
⚙ devenv-lab-sim_release_device {"reservation_id":"7cd2a66dc54d9a9d"}
Done.

- Reservation ID: 7cd2a66dc54d9a9d
- Device: ecu-demo-01
- Test result: pass
- Final log lines:
  - [2026-08-28T18:58:32Z] reserved by agent-a
  - [2026-08-28T18:58:34Z] flashed ecu-demo-01 with simulated firmware image
  - [2026-08-28T18:58:36Z] ran simulated test suite on ecu-demo-01: result=pass

Device released back to available.
```

**Verified through service logs that calls happened through the defined
API** (not arbitrary host shell commands):

```
$ docker logs lab-sim | grep lab_sim.server | tail -6
INFO:lab_sim.server:release_device: caller=agent-a reservation=b5b881cfd2af0efc
INFO:lab_sim.server:reserve_device: caller=agent-a device=ecu-demo-01 reservation=7cd2a66dc54d9a9d
INFO:lab_sim.server:flash_device: caller=agent-a reservation=7cd2a66dc54d9a9d
INFO:lab_sim.server:run_test: caller=agent-a reservation=7cd2a66dc54d9a9d result={'device': 'ecu-demo-01', 'result': 'pass'}
INFO:lab_sim.server:get_logs: caller=agent-a reservation=7cd2a66dc54d9a9d lines=3
INFO:lab_sim.server:release_device: caller=agent-a reservation=7cd2a66dc54d9a9d
```

### State-handle hijacking rejected (adversarial check, MCP client)

Reserved `bms-demo-01` as `agent-a`, then attempted `get_logs` on that same
`reservation_id` authenticated as `agent-b` (a distinct, valid token):

```
--- hijack attempt with token=tok-bbb on reservation=b5b881cfd2af0efc ---
isError: True content: Error executing tool get_logs
```

```
$ docker logs lab-sim | tail -3
lab_sim.devices.ReservationOwnershipError: reservation 0aaa36169228a0db is not owned by caller 'agent-b'
...
mcp.server.mcpserver.exceptions.UnexpectedToolError: Error executing tool get_logs
```

Rejected as intended — a valid bearer token for a *different* caller does
not grant access to someone else's reservation ID.

### Unauthenticated request rejected

```
$ curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8300/mcp/
401
$ curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8300/mcp/ -H "Authorization: Bearer wrong-token"
401
```

### Container health

```
$ docker compose ps lab-sim
NAME      IMAGE                         SERVICE   STATUS
lab-sim   devenv-cloud/lab-sim:latest   lab-sim   Up (healthy)
```

## Known limitations / not in scope for this step

- `LabSimulator` state is in-memory only — it resets on container restart.
  Acceptable for a simulator per the step's own framing ("Do not use
  physical hardware yet... against simulated devices"); a real lab-server
  would need persistent reservation state and would also query OPA's
  decision API per `docs/ARCHITECTURE.md`'s L2 diagram — OPA is a Phase 5
  concern, not built yet, and is intentionally not wired in here.
- The `docs-server` stdio process is spawned by the harness itself
  (`opencode.jsonc`'s `type: local`); it has no independent container or
  health check by design (stdio has no listening socket to probe).

## Addendum: fix for `get_build_instructions()` Makefile target-parsing bug (Step 00402)

Independent re-running of `get_build_instructions()` after the initial M11
delivery found that its Makefile parser matched *any* unindented line
containing `:` — including variable assignments (`SHELL := /bin/bash`,
`COMPOSE := docker compose`), which were then emitted as fake `make SHELL`
/ `make COMPOSE` "targets". Fixed in
`mcp/docs-server/src/docs_server/server.py` by excluding lines matching
`NAME := ...` / `NAME ?= ...` (and other assignment operators) before the
first `:`.

Regression check (`scripts/verify-docs-server-makefile-targets.sh`), run
directly against the fixed `get_build_instructions()`:

```
$ scripts/verify-docs-server-makefile-targets.sh
## Makefile targets
...
---

# Makefile targets

- `make doctor`
- `make up`
- `make down`
- `make status`
- `make logs`
- `make coder-workspace-build`
- `make embedded-workspace-build`
- `make runner-build`
- `make runner-run`
- `make temporal-worker-build`
- `make temporal-demo-start`
PASS: no variable-assignment lines parsed as Makefile targets
```

No `SHELL` or `COMPOSE` entries remain in the parsed `# Makefile targets`
section; `make doctor` (a real target) is still present, confirming the fix
excludes assignments without dropping genuine targets.

Note: a long-running `devenv-docs` MCP process attached to an existing
harness session (e.g. an already-open `opencode` session from before this
fix) will keep serving the old, buggy parse until that stdio process is
restarted — the fix takes effect on the *next* process spawn, consistent
with `type: local` MCP servers being started once per session.
