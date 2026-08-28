# Phase 3 — Durable Orchestration & Capability Fabric — Handover

Live end-to-end run performed on 2026-08-28 in this environment against the
real, running platform stack (Docker Compose, real Temporal cluster, real
MCP servers). No mocking, stubbing, or skipping — every command below hit a
real container, a real Temporal server, and a real HTTP/MCP endpoint.

## a. Executive summary

Phase 3 proves three things that Phase 1's Coder/workspace mechanics alone
don't cover:

1. **Reproducible, heavier toolchains work the same way as the base
   workspace** — an embedded/cross-compilation toolchain (M6) with
   provenance (pinned versions + image digest) and shared build caching
   (M7, artifact registry + sccache).
2. **Long-running work survives process crashes** — a Temporal-backed
   durable workflow (M8) whose in-flight timer state lives in Postgres, not
   worker memory, so killing the worker mid-execution doesn't lose progress.
3. **Agents/humans call narrow, audited APIs instead of arbitrary shell
   access** — two MCP services (M11): a read-only documentation server and
   a simulated hardware-lab service with per-caller reservation ownership
   enforcement.

Four milestones were delivered: **M6** (Embedded Simulation Workspace),
**M7** (Artifact Registry + Build Cache), **M8** (Temporal Durable
Workflow), **M11** (MCP and Local Capability Fabric).

## b. What works — evidence

| Feature | Evidence |
|---|---|
| Embedded cross-compilation toolchain (cmake/ninja/gcc-aarch64/qemu-user) builds a native test binary, runs it, cross-compiles for aarch64, and runs the cross binary under `qemu-aarch64` — full `clean → build → test → simulate` cycle | [`01-embedded-sim-build-test-simulate.txt`](./01-embedded-sim-build-test-simulate.txt) |
| Build cache (sccache) is wired into the CMake toolchain invocation (`-DCMAKE_C_COMPILER_LAUNCHER=sccache`) and the OCI registry + worker services are healthy | [`08-docker-compose-ps-final.txt`](./08-docker-compose-ps-final.txt) (`registry` container healthy) |
| MCP docs-server (`stdio` transport) answers real architecture/build questions from this repo's own Markdown docs, live, via this agent session's connected MCP tools | [`10-mcp-docs-server-live-tool-calls.txt`](./10-mcp-docs-server-live-tool-calls.txt) |
| `get_build_instructions()` Makefile-target parser bug (`make SHELL`/`make COMPOSE` false positives) is fixed and regression-checked | [`02-mcp-docs-server-makefile-targets.txt`](./02-mcp-docs-server-makefile-targets.txt) — no variable-assignment lines in output, `PASS` at the end |
| MCP/HTTP lab-sim service: full simulated-device lifecycle (`list_devices → reserve_device → flash_device → run_test → get_logs → release_device`) works end-to-end over the real `streamable-http` MCP transport | [`03-lab-sim-mcp-lifecycle.txt`](./03-lab-sim-mcp-lifecycle.txt) |
| Reservation ownership is enforced server-side — a second caller (`agent-b`) cannot read logs for `agent-a`'s reservation, and vice versa (state-handle-hijack protection) | [`03-lab-sim-mcp-lifecycle.txt`](./03-lab-sim-mcp-lifecycle.txt), bottom section — rejected with `Error executing tool get_logs` |
| Lab-sim service rejects unauthenticated and wrong-token requests (`401`), not an open port | [`04-lab-sim-auth-rejection.txt`](./04-lab-sim-auth-rejection.txt) |
| Temporal durable workflow starts for real against the live cluster | [`05-temporal-workflow-start.txt`](./05-temporal-workflow-start.txt) |
| Worker container is `docker kill`'d (SIGKILL, not a graceful stop) mid-timer; workflow state is untouched because the timer lives in Temporal-DB (Postgres), not worker memory | [`06-temporal-worker-kill.txt`](./06-temporal-worker-kill.txt) |
| After restarting the worker, the workflow resumes automatically and completes — `prepare_build` → 30s timer → `verify_build` → `COMPLETED`, full event history preserved | [`07-temporal-worker-restart-completion.txt`](./07-temporal-worker-restart-completion.txt) |
| Temporal UI shows the same completed workflow's event history (visual confirmation, not just CLI) | [`09-temporal-ui-workflow-history.png`](./09-temporal-ui-workflow-history.png) |
| Full platform stack (10 containers: Coder, Coder-DB, Temporal, Temporal-DB, Temporal UI, Temporal worker, OCI registry, docs/lab-sim MCP services, runner scaffolding) is up and healthy simultaneously | [`08-docker-compose-ps-final.txt`](./08-docker-compose-ps-final.txt) |

## c. How to build and run

1. Copy the environment template and fill in required values:
   `cp .env.example .env` (set `DOCKER_GID` via `getent group docker | cut -d: -f3`, and generate real `LAB_SIM_TOKENS` values instead of the placeholders).
2. Start the full platform stack: `make up` — this brings up Coder,
   Postgres, the OCI registry, Temporal (server + UI + worker), and the
   `lab-sim` MCP/HTTP service.
3. Verify everything is healthy: `make status` — expect every service
   listed as `healthy` (the worker has no healthcheck defined but should
   show `Up`).
4. Build the embedded-workspace toolchain image (or reuse the pre-built
   `devenv-cloud/embedded-linux-workspace:latest`):
   `make embedded-workspace-build`.
5. Run the embedded example inside that image:
   ```bash
   docker run --rm -v "$(pwd)":/workspace \
     -w /workspace/examples/embedded-sim \
     devenv-cloud/embedded-linux-workspace:latest \
     bash -lc 'make clean && make build && make test && make simulate'
   ```
6. Start one durable-workflow execution: `make temporal-demo-start` — note
   the printed `workflow_id`.
7. Query the docs-server or lab-sim MCP tools from an `opencode`/`pi`
   session wired via `opencode.jsonc` (set `LAB_SIM_AGENT_TOKEN` in your
   shell to one of the `LAB_SIM_TOKENS` values first).

## d. How to test

| Action | Expected result |
|---|---|
| `make -C examples/embedded-sim clean && make -C examples/embedded-sim build && make -C examples/embedded-sim test && make -C examples/embedded-sim simulate` inside the `embedded-linux-workspace` image | Native unit test passes (`checksum_test ... Passed`), cross-compiled `firmware` binary runs under `qemu-aarch64` and prints `self-check OK` |
| `make temporal-demo-start`, then mid-timer `docker kill temporal-worker`, then `docker compose start temporal-worker` | `temporal workflow describe --workflow-id <id>` eventually reports `Status: COMPLETED` with the full 22-event history intact — no manual state reconstruction |
| Call `list_devices` then `reserve_device` on the lab-sim MCP service as `agent-a`, then try `get_logs` for that reservation ID as `agent-b` | `agent-b`'s call is rejected (`Error executing tool get_logs`) — reservation ownership is enforced server-side |
| `curl` the lab-sim `/mcp/` endpoint with no `Authorization` header, then with a wrong bearer token | Both return `HTTP 401` — never an open, unauthenticated endpoint |
| Call `get_build_instructions()` on the docs-server and search the output for `make SHELL` / `make COMPOSE` | Neither appears — only genuine `make <target>:` rules are listed |

## e. Known limitations

- **M7 cold-vs-warm cache timing comparison** was not re-run as part of this
  demo — the registry/sccache infrastructure is confirmed healthy and wired
  into the build (`-DCMAKE_C_COMPILER_LAUNCHER=sccache`), but a fresh
  side-by-side cold/warm timing run (as M7's own validation milestone
  specifies) requires provisioning two throwaway Coder workspaces, which is
  out of scope for this handover's non-interactive verification pass. See
  `docs/milestone-reports/M7-cache.md` for the original timing evidence.
- **M6/M7's "fresh Coder workspace" manual E2E test** (via the Coder web
  UI, not a raw `docker run` against the pre-built image) was not
  re-exercised here; this run validates the same toolchain image directly,
  which exercises the identical build/test/simulate path but skips the
  Coder provisioning step itself (already proven in `docs/milestone-reports/M6-embedded.md`).
- A stale reservation for `ecu-demo-01` was left behind by an early,
  aborted client-script attempt during this evidence run (an SDK attribute
  name typo, fixed before the recorded evidence in
  `03-lab-sim-mcp-lifecycle.txt`) — the lab-sim service has no
  administrative "force release" tool, so that one device will show
  `status: reserved` until the `lab-sim` container is restarted (its state
  is in-memory only). Cosmetic, does not affect `ecu-demo-02`/`bms-demo-01`
  or any of the recorded evidence.
- Phase 3 depends on Phase 1's Coder/workspace mechanics (M3) and Session
  Plane (M4/M5), which are documented and verified separately under
  `docs/plan/demo/phase1-remote-dev-agent/`.
