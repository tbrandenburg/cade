# Architecture — cade

Condensed C4-model view of the platform described in `docs/INITIAL.md` and `docs/cade.png`. This is a summary for quick orientation — `docs/INITIAL.md` (Section 2, the seven-layer model) remains the source of truth for details; this file must be kept in sync with it, not the other way around.

C4 levels used: **Context** (L1), **Container** (L2), **Component** (L3, one representative slice). A Code-level (L4) diagram is intentionally omitted — the codebase doesn't exist yet, and this doc will drift immediately if it tries to describe classes/functions before implementation.

---

## L1 — System Context

Who/what interacts with the platform, and what external systems it depends on.

```mermaid
C4Context
    title cade — System Context

    Person(dev, "Developer", "Human operating VS Code, a browser, or a CLI as the control surface")

    System(platform, "Private Developer Platform", "Single Linux server: Docker-first dev environment, agent sessions, GitHub-coordinated automation")

    System_Ext(github, "GitHub.com", "Repos, Issues, PRs, Actions, gh-aw — the coordination plane (Free tier)")
    System_Ext(llm, "LLM Provider", "GitHub Copilot / Claude / OpenAI / Gemini — exactly one chosen backend for opencode/pi")
    System_Ext(tailscale, "Tailscale", "WireGuard mesh — interactive remote access only, never for automation")

    Rel(dev, platform, "Develops via VS Code / browser / CLI, over Tailscale or LAN")
    Rel(platform, github, "Outbound HTTPS only — self-hosted runner polls, never receives inbound connections")
    Rel(github, platform, "Dispatches jobs / triggers gh-aw reasoning, via the outbound runner connection")
    Rel(platform, llm, "Agent CLI harness (opencode/pi) calls out for completions")
    Rel(dev, tailscale, "Connects through")
    Rel(tailscale, platform, "Reaches private server, no public ports opened")
```

**Key constraint (Rule 6):** every arrow into the platform is either the developer's own Tailscale/LAN connection, or GitHub's runner polling outbound — there is no inbound path that originates from outside.

---

## L2 — Container Diagram

The platform's internal building blocks, mapped to the seven-layer model (`docs/INITIAL.md` Section 2.1). "Container" here is a C4 container (a deployable/runnable unit — mostly Docker containers, in this platform's case almost literally).

```mermaid
C4Container
    title cade — Container Diagram (single Linux server)

    Person(dev, "Developer")
    System_Ext(github, "GitHub.com")
    System_Ext(llm, "LLM Provider")

    Container_Boundary(server, "Private Linux Server") {

        Container(agenthost, "VS Code Agent Host", "AHP", "L2 Session Plane. Owns agent sessions independently of any attached client. Reached over SSH (via `coder config-ssh`) or a dev tunnel.")

        Container(coder, "Coder Community", "Terraform + Docker", "L4 Execution Plane control. Provisions/destroys Docker workspaces from templates; separates ephemeral container from persistent home volume.")

        Container(workspace, "Docker Workspace(s)", "Dev Container", "L4 Execution Plane. repo + toolchain + opencode/pi (sandboxed via srt + VS Code agent sandbox) + git worktrees per parallel session. Three Coder templates: `docker-standard`/`embedded-linux` (fixed pre-built image) and the additive `devcontainer` template (Issue #6), which instead builds/runs the workspace from the cloned repo's own `.devcontainer/devcontainer.json` via `@devcontainers/cli` at start time.")

        Container(runner, "Self-Hosted GitHub Runner", "Docker, JIT/ephemeral", "L5 Coordination. Outbound-only poller; executes deterministic Actions jobs and gh-aw's reasoning step.")

        Container(temporal, "Temporal OSS", "Server + Worker + UI", "L5 Coordination. Durable orchestration — Postgres-backed persistence & visibility, survives worker crashes.")

        Container(mcp, "MCP Servers", "docs-server, lab-server", "L6 Tool/Context Fabric. stdio or authenticated transport; narrow, auditable tool surface instead of shell access.")

        Container(cache, "Artifact/Cache Services", "OCI registry, sccache", "L4 support. Speeds up fresh-workspace builds; registry is auth-protected/internal-only.")

        Container(omnigent, "Omnigent Server", "Server + Postgres", "L2 Session Plane (Issue #43). Shared, singleton Coder Agents alternative host/UI — own -db service, platform-control only, no host port beyond a 127.0.0.1 loopback publish.")

        Container_Boundary(gov, "Governance (L7)") {
            Container(openbao, "OpenBao", "Secrets", "TLS, revoked root token, backed-up unseal keys.")
            Container(opa, "OPA", "Policy", "Rego policies + opa test suite; MCP lab-server queries its decision API.")
            Container(keycloak, "Keycloak", "Identity (optional)", "Gated behind a compose profile; not enabled by default.")
        }

        Container_Boundary(obs, "Observability (L7)") {
            Container(otel, "OTel Collector", "Telemetry pipeline", "Bound to internal hostnames, not 0.0.0.0.")
            Container(prom, "Prometheus", "Metrics store", "Required backend — never exposed publicly.")
            Container(grafana, "Grafana OSS", "Dashboards", "Provisioned from version-controlled JSON.")
        }
    }

    Rel(dev, agenthost, "AHP, over SSH/dev tunnel")
    Rel(agenthost, workspace, "Runs inside")
    Rel(coder, workspace, "Provisions/destroys")
    Rel(workspace, llm, "opencode/pi call out for completions")
    Rel(github, runner, "Dispatches jobs (outbound poll)")
    Rel(runner, workspace, "Runs deterministic builds via Docker")
    Rel(runner, temporal, "Starts/observes durable workflows")
    Rel(temporal, mcp, "Activities call MCP tools")
    Rel(mcp, opa, "Decision query before privileged action")
    Rel(workspace, mcp, "Agent calls tools instead of shelling out")
    Rel(runner, openbao, "Reads secrets")
    Rel(otel, prom, "Exports metrics")
    Rel(grafana, prom, "Queries")
    Rel(workspace, omnigent, "Outbound-only WSS tunnel: host login + chat, replicated via workspace startup script (Issue #43) — no inbound path into the platform, per L1 Rule 6")
```

---

## L3 — Component Diagram (representative slice: the Docker Workspace)

The workspace is the container most agents will actually work inside of, so it's the one slice worth a component-level breakdown.

```mermaid
C4Component
    title cade — Components inside a Docker Workspace

    Container_Boundary(ws, "Docker Workspace (ephemeral, except /home/coder)") {
        Component(repo, "Repo checkout + worktrees", "Git", "1 worktree per parallel agent session (M5 policy)")
        Component(toolchain, "Toolchain", "gcc/cmake/ninja/qemu-user, or hello-service's simple stack", "Pinned base image + digest for provenance")
        Component(vscodeagent, "VS Code Agent Host process", "Agent Host + AHP server", "Started on remote-session connect; chat.agent.sandbox.enabled")
        Component(opencode, "opencode CLI", "harness", "Wrapped: srt opencode --")
        Component(pi, "pi CLI", "harness", "Wrapped: srt pi --")
        Component(srt, "srt (Sandbox Runtime)", "bubblewrap-based", "Filesystem/network allowlist; denies ~/.ssh, ~/.aws, ~/.claude, ~/.copilot, .env")
        Component(omnigenthost, "omnigent host CLI", "harness", "Issue #43. Disposable host identity (OMNIGENT_HOST_ID/NAME); spawns opencode via a PATH shim, srt-wrapped by default")
        Component(home, "/home/coder", "persistent volume", "Survives container replace: repo, .config, .cache, agent session/memory state, .srt-settings.json")
    }

    Rel(vscodeagent, opencode, "Spawns / hosts session for")
    Rel(vscodeagent, pi, "Spawns / hosts session for")
    Rel(opencode, srt, "Runs wrapped in")
    Rel(pi, srt, "Runs wrapped in")
    Rel(omnigenthost, srt, "Spawns opencode wrapped in (PATH shim; default sandbox mode)")
    Rel(srt, repo, "Filesystem-restricted access to")
    Rel(vscodeagent, home, "Session/memory state persisted to")
    Rel(toolchain, home, "Build cache, dependency state persisted to")
```

---

## The Three Durability Levels (cross-cutting, applies to every container above)

This is the single most important cross-cutting property of the architecture (`docs/INITIAL.md` Section 2.2 / Rule 7) — do not assume proving one implies the others:

| Level | What survives | Proven by |
|---|---|---|
| UI durability | Closing/reopening VS Code | AHP / Agent Host (M4) |
| Workspace durability | Workspace container restart | Coder's persistent home volume (M3/M6, re-verified with a byte-exact marker file at M16) — a *template* property, not automatic |
| Process durability | Worker crash mid-execution | Temporal's Event History in Postgres (M8) |

---

## Maintenance note

This file is a **summary**, condensed on purpose. When a phase changes the architecture (new container, new component, changed data flow), update this file as part of that phase's mandatory "Documentation & Agent Instructions Update" step (see `docs/phases/README.md`), alongside `docs/architecture.md`, `docs/operations.md`, and `docs/security.md`. If this file and `docs/INITIAL.md` Section 2 ever disagree, `docs/INITIAL.md` wins until this file is corrected.

## Issue #5 MVP — Build-in-workspace Activity/Workflow

`temporal-worker` gained a scoped-down slice of the "run Temporal workflows
in predefined workspaces with build tools installed" feature: a
`run_build_command` Activity (`temporal/src/demo/build_activity.py`) uses
the `docker` Python SDK to run a single command in a short-lived container
built from `cade/coder-workspace:latest` (or any other pre-built image),
capture its stdout/stderr and exit code, and remove the container. A
minimal `BuildWorkflow` (`temporal/src/demo/build_workflow.py`) calls this
Activity once; `temporal/src/demo/build_starter.py` and
`make temporal-build-demo-start` trigger it manually. This is deliberately
the smallest useful slice of the issue's larger plan — no OPA policy gate,
no workspace-template-specific image selection, no multi-step build
pipeline — those remain follow-up work, not implemented here.

## Issue #43 (2026-08-30) — Omnigent host integration

Added the shared, singleton `omnigent-server` (+ its own `omnigent-db`
Postgres) as a new L2 Container, and `omnigent host CLI` as a new L3
Component inside the `agent-workspace` Docker Workspace, alongside
`srt`/`opencode`/`pi`. The `agent-workspace` template's startup script logs
in and runs `omnigent host ... --background --non-interactive` with a
disposable per-workspace host identity, spawning `opencode` through a PATH
shim that is `srt`-wrapped by default (`omnigent_sandbox_mode = "srt"`) —
no second, unsandboxed way to run agent turns. The workspace→server traffic
is an outbound-only WSS tunnel (workspace container dials out to
`omnigent-server:8000` on `platform-workspaces`), which is why the diagram
adds only a single `Rel(workspace, omnigent, ...)` arrow with no reverse
edge — consistent with L1 Rule 6 ("every arrow into the platform is either
the developer's own Tailscale/LAN connection, or GitHub's runner polling
outbound — there is no inbound path that originates from outside").

**Update, same day (live E2E verification):** brought up `omnigent-db` +
`omnigent-server` for real (scoped `docker compose up -d`, not the full
stack) and exercised the actual startup-script login/registration logic
against it via `docker run`/`docker exec`. Confirmed working end to end:
first-admin bootstrap (`OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD`/`_USERNAME`),
the real `POST /auth/login` + `store_token(...)` replication, and
`omnigent host --background --non-interactive` registering successfully
(`GET /v1/hosts` showed the expected host_id/name, status `online`). Three
real integration bugs surfaced and were fixed in the process (missing
`compose.yaml` env passthrough, wrong default admin username, and the
`OMNIGENT_HOST_ID`/`OMNIGENT_HOST_NAME` env-var mechanism being silently
dropped by the daemon's own env allowlist — fixed by writing
`~/.omnigent/config.yaml` directly instead) — see `AGENTS.md`'s Lessons
Learned for the full detail. The diagram/architecture shape above is
unchanged by these fixes; only the container's real env vars and the
startup script's identity-setting mechanism changed. Not yet verified live
through an actual `coder create` (no live Coder session in this
environment) — this ad-hoc `docker run`/`docker exec` proof is a scoped
stand-in, per this repo's own documented practice for validating
integration logic without a live Coder session.

**Update (Issue #45, 2026-08-30) — reverse Unix-socket bridge:** the
`coder create`-validated blocker this section's prior update deferred
turned out to be architectural, not a config gap: `srt`'s
`bwrap --unshare-net` gives the sandboxed `opencode serve` process its own
private network namespace, so its TCP loopback port is unreachable from
the unsandboxed `omnigent host` runner that needs to reach back into it —
no CLI flag/escape hatch exists in `srt` for this. Fixed with a reverse
Unix-socket bridge (Direction 4 of Issue #45's design space): Unix domain
sockets are filesystem objects, not network endpoints, so a socket file
under the shared `/tmp` bind-mount crosses the network-namespace boundary
even though a TCP port cannot. The `agent-workspace` template's
`startup_script` now runs an inside-sandbox `socat` relay (paired with
`opencode serve` inside the same `srt`/`bwrap` invocation) and an
outside-sandbox watchdog process that bridges a real TCP port back to
that Unix socket for `omnigent host` to dial. Verified fully working
end-to-end via a real omnigent chat session driving `opencode serve`
through the bridge to completion, with Issue #23's sandbox properties
(`denyRead`/`denyWrite`) confirmed not regressed. Full design rationale
and evidence: Issue #45 and `docs/milestone-reports/issue-45-bridge.md`.

