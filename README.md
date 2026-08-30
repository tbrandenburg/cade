# cade - Continuous Agentic Development Environment

**A Docker-first, single-repository private developer platform** for remote
development, agent-assisted coding, GitHub automation, durable orchestration,
and governance/observability — running entirely on one Linux server, with no
inbound Internet exposure and no paid cloud infrastructure required.

![Seven-layer architecture reference](docs/cade.png)

**Status: `0.1.0` released** — all 16 milestones across 5 phases are
delivered and evidenced. See [Project status](#project-status) below.

## Table of contents

- [What this is](#what-this-is)
- [Why it exists](#why-it-exists)
- [Repository layout](#repository-layout)
- [Quickstart](#quickstart)
  - [Resetting a Coder user's password](#resetting-a-coder-users-password)
- [User journeys](#user-journeys)
- [Makefile targets](#makefile-targets)
- [Troubleshooting](#troubleshooting)
  - [Self-signed / corporate TLS-intercepting proxy certificates](#self-signed--corporate-tls-intercepting-proxy-certificates)
- [Project status](#project-status)
- [Documentation map](#documentation-map)
- [Known limitations](#known-limitations)
- [License](#license)

## What this is

cade lets a developer open VS Code, connect to a durable remote
session over Tailscale/SSH, and drive an AI coding agent (OpenCode, Pi,
Copilot, Claude, Gemini, ...) against an isolated, reproducible Docker
workspace — with the session surviving editor restarts, workspace restarts,
and worker crashes. Everything needed to stand it up lives in this one
repository: no external SaaS dependency beyond GitHub.com (as a coordination
plane) and your own LLM provider.

It is built around three independent **durability levels**, deliberately
never conflated:

| Level | What survives | Proven by |
|---|---|---|
| UI durability | Closing/reopening VS Code | VS Code Agent Host (AHP) |
| Workspace durability | Workspace container restart | Coder's persistent home volume |
| Process durability | Worker crash mid-execution | Temporal's Event History (Postgres) |

On top of that base, the platform adds a full closed loop for real
engineering work:

- **GitHub automation** — a hardened, ephemeral (JIT) self-hosted runner
  picks up CI jobs with no inbound port and no direct Docker-socket
  exposure; an agentic (`gh-aw`) workflow can investigate a CI failure and
  open a bounded, permission-scoped GitHub issue.
- **Durable orchestration** — Temporal-backed workflows keep running across
  worker crashes, backed by Postgres event history.
- **Capability fabric** — agents and humans call narrow, audited MCP APIs
  (a read-only docs server, a simulated-hardware lab service) instead of
  arbitrary shell access, with reservation ownership enforced server-side.
- **Governance** — OpenBao holds secrets out of source code; Open Policy
  Agent (OPA) gates privileged actions (e.g. `flash_device` requires
  explicit approval) with real Rego policy, not hardcoded checks.
- **Observability** — every execution path (runner, Temporal worker, MCP
  services, containers) emits metrics/logs collected centrally and
  visualized in Grafana, correlated across services by timestamp.
- **Backup/restore & release discipline** — every category of
  non-regenerable state (repo, Coder DB, Temporal DB, OpenBao, workspace
  home volumes) is backed up and proven restorable end-to-end.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full C4-model
breakdown (Context → Container → Component) and
[`docs/INITIAL.md`](docs/INITIAL.md) for the authoritative, detailed
implementation plan this repository executes.

## Why it exists

Most "cloud dev environment" products require a SaaS account, a paid
control plane, and outbound trust in a third party's infrastructure just to
edit code. cade proves the same developer experience — persistent
remote workspaces, AI-agent-assisted coding, CI automation, durable
long-running jobs, policy-gated access to real/simulated hardware, and
centralized observability — is achievable on a single Linux box you already
own, using only open-source components (Coder, Temporal, OpenBao, OPA,
Prometheus/Loki/Grafana) wired together with Docker Compose and Terraform.

## Repository layout

```
cade/
├── Makefile                     # host prep, stack lifecycle, image builds, backup/restore
├── compose.yaml                  # full platform stack (Coder, Temporal, MCP, governance, observability)
├── coder/                         # workspace container images + Terraform templates
│   ├── Dockerfile
│   ├── devcontainer/                # devcontainer template's bootstrap image (Issue #6)
│   └── templates/                  # docker-standard, embedded-linux, devcontainer workspace templates
├── agent-host/                    # VS Code Agent Host / sandbox security baseline
├── runner/                         # self-hosted GitHub Actions runner (JIT, ephemeral)
├── temporal/                       # Temporal worker image + demo durable workflow
├── mcp/                             # MCP servers: docs server, simulated-hardware lab-sim
├── governance/                      # OpenBao + OPA policy-gated capability fabric
├── observability/                    # OTel Collector, Prometheus, Loki, Grafana dashboards
├── backup/                            # backup/restore scripts and policy
├── scripts/                            # host checks, SSH bridging, worktree/session tooling
├── sessions/                            # agent session & git-worktree isolation policy
├── examples/
│   ├── hello-service/                    # minimal Python toolchain smoke test
│   └── embedded-sim/                      # cross-compiled embedded firmware example
├── docs/
│   ├── INITIAL.md                          # authoritative implementation plan (source of truth)
│   ├── ARCHITECTURE.md                      # condensed C4 summary of INITIAL.md
│   ├── security.md                           # security posture and known limitations
│   ├── disaster-recovery.md                   # backup/restore runbook
│   ├── phases/                                 # INITIAL.md split into 5 deliverable phases
│   ├── milestone-reports/                       # evidence report per completed milestone
│   └── plan/                                     # internal plan-driven build process (factory.sh state)
├── VERSION.md                                     # release history
└── AGENTS.md                                       # accumulated agent-facing knowledge for this repo
```

## Quickstart

Requirements: a Linux host with Docker Engine + Compose v2, ~100 GB free
disk, and outbound HTTPS access. No inbound ports need to be exposed beyond
what you choose to reach over your own VPN/Tailscale network.

```bash
# 1. Verify the host meets the baseline requirements
make doctor

# 2. Configure environment (versions, ports, DB credentials, tokens)
cp .env.example .env
$EDITOR .env   # set DOCKER_GID: getent group docker | cut -d: -f3

# 3. Start the platform control plane (Postgres + Coder)
make up

# 4. Bring up the remaining services (runner support, Temporal, MCP,
#    governance, observability)
docker compose up -d
make status   # wait until every service is (healthy)/Up

# 5. One-time: initialize/unseal OpenBao and rotate credentials
make governance-bootstrap

# 6. First login: open http://localhost:7080 in a browser and complete
#    Coder's first-run admin setup — or from the CLI:
coder login http://localhost:7080
#    (If the browser doesn't show a "create first admin" form, an admin
#    likely already exists on this stack from a previous run — see
#    "Resetting a Coder user's password" below to regain access instead
#    of wiping the deployment.)

# 7. Build the workspace image(s) workspaces will run
make coder-workspace-build          # docker-standard template
make embedded-workspace-build       # embedded-linux template (optional)
make devcontainer-workspace-build   # devcontainer template (optional, Issue #6)

# 8. Push the Terraform template(s) and create a workspace
make templates-push                 # pushes all three templates in one shot
# (or push just one: coder templates push docker-standard -d coder/templates/docker-workspace --yes)
coder create <owner>/<name> --template docker-standard --yes \
  --parameter github_token=<token or empty> --parameter agent_capable=true
```

Once a workspace is running, `scripts/configure-coder-ssh.sh` wires up local
SSH config so VS Code's Agent Host can connect to it as
`ssh coder.<workspace-name>`, and `scripts/verify-ahp-session.sh` proves the
Agent Host protocol handshake actually succeeds end-to-end.

### Resetting a Coder user's password

Coder's admin account has no seeded/default credentials — it's created
either via the first-run browser wizard or `coder login`'s
`--first-user-*` flags (see Quickstart step 6), and the password only ever
exists wherever you first set it. If it's lost, or a fresh clone shows a
normal login form instead of the "create first admin" wizard (meaning an
admin already exists from a previous run), reset that user's password
directly rather than wiping the whole deployment.

**Coder authenticates by email, not username** — the built-in
`coder reset-password <username>` subcommand (and most other CLI
subcommands) take a `<username>`, but the login form and
`/api/v2/users/login` API both need that user's *email*, which isn't
necessarily the same string. `scripts/coder-reset-password.sh` wraps
both steps — it looks up the email for the given username, runs
`reset-password`, then prints the email you actually need to log in with:

```bash
scripts/coder-reset-password.sh <username>
#   Resetting password for username 'admin' (email: admin@cade.local)...
#   > Enter new  password : > Confirm  password :
#   Password has been reset for user admin!
#
#   Log in with EMAIL (not username): admin@cade.local
#     Browser: http://localhost:7080
#     CLI:     coder login http://localhost:7080
```

It only touches that one user row — templates, workspaces, and every
other account are untouched. Equivalent to running the two steps by hand:

```bash
docker exec -i coder /opt/coder reset-password <username> \
  --postgres-url "postgresql://${CODER_PG_USER:-coder}:${CODER_PG_PASSWORD:-coder}@coder-db/${CODER_PG_DB:-coder}?sslmode=disable"
docker exec coder-db psql -U "${CODER_PG_USER:-coder}" -d "${CODER_PG_DB:-coder}" \
  -c "SELECT username, email FROM users WHERE deleted = false;"
```

Only wipe `coder-db` entirely (`docker compose down && docker volume rm
devenv-cloud_coder_db_data && make up`) if you actually want to destroy
every workspace/template/user and start over — not as a password-reset
shortcut.

### AI providers/models quickstart

Reconcile the AI providers/models Coder offers users (Issue #13) once the
stack is up:

```bash
make up                # if not already running
make ai-token           # mints an admin session token
$EDITOR .env            # set the minted token + any provider API keys
make ai-bootstrap        # reconciles coder/ai/{providers,models}.yaml into Coder
make verify-ai            # proves it end to end against the live stack
```

See `docs/ai-coder.md` for the entitlement boundaries (what's Premium-only
on this deployment), the repeatability model, and MCP/CI automation
details.

## User journeys

Each journey below is a self-contained quick start for one thing the
platform is for. See `AGENTS.md`'s "How to run the full end-to-end scenario
yourself" for the complete, combined walkthrough.

<details>
<summary><strong>Journey 1 — Remote dev workspace + AI coding agent</strong></summary>

Get a fully provisioned, reproducible Docker workspace with git, Python,
Node, GitHub CLI, and AI agent CLIs (`opencode`, `pi`) pre-installed, with
this repo already cloned.

```bash
make up && make status
make coder-workspace-build
coder templates push docker-standard -d coder/templates/docker-workspace --yes
coder create <owner>/<name> --template docker-standard --yes \
  --parameter github_token=<token> --parameter agent_capable=true
scripts/configure-coder-ssh.sh
ssh coder.<name>   # or open http://<server-ip>:7080 in a browser (code-server)
```

Inside the workspace:

```bash
make -C examples/hello-service build && make -C examples/hello-service test
opencode run --model opencode/big-pickle "Investigate why this test fails and propose a fix"
```

Each agent session gets its own git worktree
(`scripts/create-agent-worktree.sh`), and runs inside a `tmux` session so it
survives editor disconnects. See `docs/milestone-reports/M4-agent-host.md`
and `M5-sessions.md`.
</details>

<details>
<summary><strong>Journey 2 — GitHub CI on your own hardware</strong></summary>

Run GitHub Actions jobs on your own server via an ephemeral, outbound-only
self-hosted runner — no inbound port, no direct Docker-socket exposure.

```bash
make runner-build
bash scripts/runner-jit-start.sh    # registers, picks up exactly one job, self-destructs
gh workflow run runner-smoke.yml && gh run watch --exit-status
```

An optional agentic layer (`gh aw compile` → `.github/workflows/investigate-failure.lock.yml`)
watches CI failures and can have an AI agent investigate root cause and open
a scoped GitHub issue (requires provisioning AI-engine credentials as a
repo secret — see `docs/security.md`).
</details>

<details>
<summary><strong>Journey 3 — Durable workflow that survives a crash</strong></summary>

Prove long-running work survives a worker crash mid-execution, because its
state lives in Postgres (via Temporal), not worker memory.

```bash
make temporal-worker-build
make temporal-demo-start        # prints workflow_id
docker compose restart temporal-worker   # kill it mid-timer, on purpose
temporal workflow describe --address 127.0.0.1:7233 --workflow-id <id>
# -> eventually reports Status: COMPLETED, full event history intact
```
</details>

<details>
<summary><strong>Journey 4 — Policy-gated access to simulated hardware (MCP)</strong></summary>

Call a narrow, audited API instead of arbitrary shell access to interact
with a simulated hardware lab, gated by a real OPA policy.

```bash
make governance-bootstrap   # one-time: init/unseal OpenBao, rotate credentials
make governance-verify      # opa test 6/6 + live MCP allow/deny round trip
```

Wire an `opencode`/`pi` session to the `lab-sim` MCP tools via
`opencode.jsonc` (set `LAB_SIM_AGENT_TOKEN` first), then:
`list_devices → reserve_device → run_test` succeeds; `flash_device` without
`approved=true` is denied by policy, not by convention.
</details>

<details>
<summary><strong>Journey 5 — Observe everything in one dashboard</strong></summary>

Correlate a build, a Temporal workflow, and MCP calls by timestamp in a
single Grafana dashboard instead of grepping five container logs.

```bash
make temporal-demo-start
open http://127.0.0.1:3001   # "Phase 4 - Observability (Minimum Dashboard)"
```
</details>

<details>
<summary><strong>Journey 6 — Back up and restore the whole platform</strong></summary>

```bash
make backup          # git bundle, Coder DB, Temporal DB, OpenBao snapshot + unseal keys, home volumes
make restore-test     # destroys and restores from the latest backup set
```

See [`docs/disaster-recovery.md`](docs/disaster-recovery.md) for the full
procedure and the OpenBao-specific gotcha (a restored OpenBao instance
always comes back **sealed**).
</details>

<details>
<summary><strong>Journey 7 — Run a build command in a predefined workspace, durably, via Temporal</strong></summary>

Trigger a real build/test command inside a short-lived container built
from a pre-defined workspace image, orchestrated by a durable Temporal
workflow — gated by a fail-closed OPA policy, not a shared Docker socket.

```bash
make temporal-worker-build
make temporal-build-demo-start
# -> result={"exit_code": 0, "ok": true, "output": "hello\n"}
```

Only images on the `build.authz` allow-list
(`governance/opa/policy/build_authz.rego`) may run — an arbitrary image is
denied before a single container is created:

```bash
docker run --rm --network platform-control -e TEMPORAL_ADDRESS=temporal:7233 \
  -e DEMO_TASK_QUEUE=demo-durable-workflow --entrypoint python \
  cade/temporal-worker:latest -m demo.build_starter \
  --image evil/attacker:latest --command echo hi --wait
# -> result={"error": "denied by build.authz policy for image='evil/attacker:latest'", "ok": false}
```

See `docs/security.md`'s "Issue #5" section for the `build-docker-proxy`
isolation this runs through.
</details>

<details>
<summary><strong>Journey 8 — A repo's own devcontainer.json as the workspace blueprint</strong></summary>

Instead of a fixed pre-built workspace image, run a Coder workspace whose
toolchain comes entirely from the cloned repo's own
`.devcontainer/devcontainer.json`, built at start time — no manual
template maintenance per project.

```bash
make devcontainer-workspace-build
coder templates push devcontainer -d coder/templates/devcontainer --yes
coder create <owner>/<name> --template devcontainer --yes \
  --parameter github_token=<token> --parameter agent_capable=false \
  --parameter devcontainer_path=examples/hello-service/.devcontainer
```

Under the hood, each workspace runs its own **nested, per-workspace**
Docker-in-Docker daemon (not a shared host socket) so `devcontainer.json`
builds/pulls/execs stay isolated per workspace. See
`docs/devcontainer-security-notes.md` for the full design rationale and
its accepted `privileged`-container tradeoff.
</details>

<details>
<summary><strong>Journey 9 — Reconnect to a running VS Code Agent Host session (AHP)</strong></summary>

Give an AI coding agent a durable session that keeps running after you
close VS Code, by connecting through VS Code's own Agent Host over AHP
(Agent Host Protocol) instead of a plain terminal process.

```bash
make coder-workspace-build
coder templates push docker-standard -d coder/templates/docker-workspace --yes
coder create <owner>/<name> --template docker-standard --yes \
  --parameter github_token=<token or empty> --parameter agent_capable=true
scripts/configure-coder-ssh.sh
```

In VS Code Desktop: open the Agents window → select `coder.<name>` → start
an agent session → give it a multi-minute task → close the project window
→ reopen the Agents window later → reconnect to `coder.<name>` → the same
session is still there, and the agent kept working while no editor was
attached.

```bash
scripts/verify-agent-host.sh coder.<name>   # process reachable over SSH
scripts/verify-ahp-session.sh coder.<name>  # actual AHP JSON-RPC handshake
```

**Verified 2026-08-29** against a live stack: workspace creation with
`agent_capable=true`, `scripts/configure-coder-ssh.sh`'s SSH bridge
(`ssh coder.<name>`), and both verification scripts all behave exactly as
documented. `scripts/verify-agent-host.sh`/`verify-ahp-session.sh` both
correctly report failure with no Agent Host process found, because VS
Code's Agent Host is started lazily by a real VS Code Desktop client on
first Agents-window connect — it is not part of workspace startup, and no
non-interactive environment can substitute for that client. This matches
the documented behavior in `scripts/verify-agent-host.sh` itself. **Known
gap**: `opencode`/`pi` are not AHP adapters and never go through the Agent
Host — they get session continuity from a detached `tmux` session
instead (Journey 1). See `docs/phases/phase-1-remote-dev-agent.md`'s M4/M5
sections and `docs/milestone-reports/M4-agent-host.md` for the full VS
Code-Desktop-driven proof.
</details>

<details>
<summary><strong>Journey 10 — Label a GitHub issue, get an AI agent to work on it</strong></summary>

Trigger a real Coder Agents chat straight from GitHub: label an issue,
and a self-hosted CI job pre-creates a fresh Coder workspace, starts an
AI agent chat seeded with the issue's own title/body, and posts a
comment back on the issue linking to the live chat.

One-time setup (manual, per deployment):

```bash
# 1. Create a real GitHub OAuth App, then set in .env:
#    GITHUB_OAUTH_CLIENT_ID / GITHUB_OAUTH_CLIENT_SECRET
# 2. Uncomment CODER_EXTERNAL_AUTH_0_* in compose.yaml, then:
docker compose up -d coder
# 3. In the Coder UI: Account -> External Authentication -> link GitHub.
# 4. Provision repo secrets/vars for .github/workflows/agent-chat.yml:
gh secret set CODER_URL --body "http://coder:7080"       # internal hostname, not localhost
gh secret set CODER_SESSION_TOKEN --body "<long-lived Coder API token>"
gh variable set CODER_AGENT_WORKSPACE_TEMPLATE_ID --body "<agent-workspace template id>"
gh variable set CODER_ORGANIZATION --body "<org name>"
```

Then, day to day:

```bash
# Runner is JIT/one-shot — start it right before triggering, not ahead of time.
bash scripts/runner-jit-start.sh
gh issue edit <n> --add-label agent-chat
```

A real Coder workspace (`agent-workspace` template) is created from
inside the CI job, a real Coder Agents chat is started against it with
the issue's title/body as its prompt, and a result comment (with a
link to the live chat) is posted back on the issue automatically.

**Verified 2026-08-29/30** against a live stack, real `issues:labeled`
trigger (not just `workflow_dispatch`): the agent performed real,
non-mocked tool-calling work (`start_workspace`, `read_file`) against a
freshly pre-created workspace, and a real comment landed on the
triggering issue. See `docs/ai-coder.md`'s "CI / unattended automation
successor path (Task 8c)" section and `AGENTS.md`'s Issue #17 entry for
the full evidence and the real bugs found (workspace name length cap,
token lifetime units, chat-reuse footgun) while proving this live.
**Known gap**: the agent did real investigative work in testing, not a
full "fix it and open a PR" loop — that end-to-end path is not yet proven.
</details>

## Makefile targets

| Target | Milestone | Purpose |
|---|---|---|
| `make doctor` | M0 | Verify host OS/arch/tooling/disk/ports meet baseline requirements. |
| `make up` | M1 | Start the platform control plane (Postgres + Coder) in the background. Also builds the `temporal-worker`/`lab-sim` images first (cache-hit, near-instant unless code changed) since compose.yaml has no `build:` stanza for them, then prints the main web UI URLs (Coder, Temporal, Grafana). |
| `make down` | — | Stop and remove the platform stack's containers (named volumes persist). |
| `make status` | — | Show status/health of every stack container. |
| `make logs` | — | Follow logs of the platform stack's containers. |
| `make coder-workspace-build` | M3 | Build the `docker-standard` workspace image. Refuses to run with uncommitted changes under `examples/`, `coder/`, or `Makefile`. Optional `CACERT=/path/to/ca-bundle.pem` for corporate TLS-intercepting proxies. |
| `make embedded-workspace-build` | M6 | Build the `embedded-linux` cross-compilation workspace image (cmake/ninja/gcc-aarch64/qemu-user). Optional `CACERT=/path/to/ca-bundle.pem` for corporate TLS-intercepting proxies. |
| `make devcontainer-workspace-build` | Issue #6 | Build the `devcontainer` template's thin bootstrap image (`cade/devcontainer-bootstrap:latest`) — Docker CLI, Node.js, `@devcontainers/cli` only; the actual toolchain comes from the target repo's own `.devcontainer/devcontainer.json`, built at workspace-start time. Optional `CACERT=/path/to/ca-bundle.pem` for corporate TLS-intercepting proxies. |
| `make templates-push` | — | Push every Coder workspace template (`docker-standard`, `embedded-linux`, `devcontainer`) to the running Coder server in one shot. Depends on all three `*-workspace-build` targets, so it also (re)builds `cade/coder-workspace`, `cade/embedded-linux-workspace`, and `cade/devcontainer-bootstrap` first (cache-hit, near-instant unless code changed), inheriting their dirty-tree refusal check. Requires the `coder` CLI on `PATH`, an authenticated session (`coder login`), and the Coder server already up/healthy. |
| `make runner-build` | M2 | Build the self-hosted GitHub Actions runner image (pinned digest + checksum-verified runner binary). Optional `CACERT=/path/to/ca-bundle.pem` for corporate TLS-intercepting proxies. |
| `make runner-run` | M2 | Start one JIT (just-in-time), ephemeral runner container. |
| `make temporal-worker-build` | M8 | Build the Temporal worker image. Optional `CACERT=/path/to/ca-bundle.pem` for corporate TLS-intercepting proxies. |
| `make lab-sim-build` | M11 | Build the lab-sim MCP service image. Optional `CACERT=/path/to/ca-bundle.pem` for corporate TLS-intercepting proxies. |
| `make temporal-demo-start` | M8 | Start one durable-workflow execution against the live Temporal cluster. |
| `make governance-bootstrap` | M12 | Init/unseal OpenBao, rotate credentials, revoke root token. Re-run whenever the `openbao` container is recreated (does not auto-unseal). |
| `make governance-verify` | M12 | Run `opa test` plus a live OPA/MCP ALLOW-`run_test` / DENY-`flash_device` round trip. |
| `make backup` | M14 | Create a timestamped backup set covering every MUST-BACK-UP category. |
| `make restore-test` | M14 | Destroy the MUST-BACK-UP resources and restore them from the latest backup set. |

`examples/hello-service/Makefile` and `examples/embedded-sim/Makefile`
additionally provide their own `build`/`test`/`run`/`clean`/`simulate`
targets — toolchain smoke tests proving a freshly provisioned workspace can
build/test unmodified code.

## Troubleshooting

### Self-signed / corporate TLS-intercepting proxy certificates

On a network behind a corporate TLS-intercepting proxy (or any self-signed
CA), builds and workspace creation can fail with variations of `x509:
certificate signed by unknown authority`. There are two distinct places
this shows up, with two distinct fixes — they are **not** interchangeable.

**1. `make *-build` targets** — failing to fetch packages (PyPI, apt,
system CA install) while building an image this repo owns a `Dockerfile`
for. Every one of these targets accepts an optional `CACERT` pointing at
your corporate CA bundle, baked into the image at build time via a
BuildKit secret (never a build arg/`COPY`, so it never lands in an image
layer):

| Target | Image built |
|---|---|
| `make coder-workspace-build CACERT=/path/to/ca-bundle.pem` | `cade/coder-workspace:latest` |
| `make embedded-workspace-build CACERT=/path/to/ca-bundle.pem` | `cade/embedded-linux-workspace:latest` |
| `make devcontainer-workspace-build CACERT=/path/to/ca-bundle.pem` | `cade/devcontainer-bootstrap:latest` |
| `make runner-build CACERT=/path/to/ca-bundle.pem` | the self-hosted GitHub Actions runner image |
| `make temporal-worker-build CACERT=/path/to/ca-bundle.pem` | `cade/temporal-worker:latest` |
| `make lab-sim-build CACERT=/path/to/ca-bundle.pem` | `cade/lab-sim:latest` |

Omit `CACERT` entirely on unrestricted networks — every one of these
Dockerfiles treats an empty/unset secret as a no-op.

**2. Workspace creation itself** (not a `make *-build` target) — failing
during Terraform's provider download step, inside the *running* `coder`
server container:

```
Error: Failed to query available provider packages
Could not retrieve the list of available versions for provider coder/coder:
could not connect to registry.terraform.io: ... tls: failed to verify
certificate: x509: certificate signed by unknown authority
```

This can't be fixed with `CACERT` on a `make *-build` target — `terraform
init` here runs inside `ghcr.io/coder/coder` itself (fetching the
`coder/coder` and `kreuzwerker/docker` provider packages needed by every
Terraform template), and that image is pulled prebuilt with no repo-owned
Dockerfile to bake a CA into, plus its non-root runtime user can't write
into the image's own `/etc/ssl/certs`. Root-caused live: Terraform (a Go
binary) merges every file found under `$SSL_CERT_DIR` into its trust pool
(its default directories already include `/etc/ssl/certs`) — reproduced
the failure by pointing `SSL_CERT_DIR` at an empty directory, then
confirmed it resolves once the existing system bundle and a CA both exist
in a directory `SSL_CERT_DIR` points to. Fix:

```bash
scripts/coder-trust-ca.sh /path/to/corporate-ca-bundle.pem
```

This copies the container's existing trust bundle plus your corporate CA
into a writable directory inside the persistent `coder_home` volume
(survives container recreation), then prints the `.env` line to point
`SSL_CERT_DIR` at it:

```bash
echo "CODER_SSL_CERT_DIR=/home/coder/.local-ca-certs" >> .env
docker compose up -d coder   # recreate so the env var takes effect
```

Retry workspace creation afterward. On unrestricted networks, leave
`CODER_SSL_CERT_DIR` unset — `compose.yaml` then passes `SSL_CERT_DIR=""`,
which Go treats identically to unset (falls back to its normal default
cert directories), so this is also a no-op by default.

## Project status

**Released: `0.1.0` (2026-08-29)** — all 16 milestones across 5 phases are
delivered, with committed evidence under
[`docs/milestone-reports/`](docs/milestone-reports/) and re-verified,
live handover evidence under [`docs/plan/demo/`](docs/plan/demo/):

| Phase | Milestones | Delivers |
|---|---|---|
| 1 — Remote Dev + Agent | M0, M1, M3, M4, M5, M9, M15 | Coder workspaces, VS Code Agent Host, agent CLIs, git worktrees, tmux persistence |
| 2 — GitHub Automation | M2, M10 | Ephemeral self-hosted runner, agentic CI-failure investigation (`gh-aw`) |
| 3 — Durable Orchestration & Capability Fabric | M6, M7, M8, M11 | Embedded toolchain, build cache, Temporal durable workflows, MCP capability fabric |
| 4 — Governance & Observability | M12, M13 | OpenBao + OPA policy gating, Prometheus/Loki/Grafana dashboard |
| 5 — Integration & Release | M14, M15, M16 | Backup/restore, full E2E acceptance, `0.1.0` tag |

Two known, documented (not silently worked-around) limitations remain open
at `0.1.0` — see [Known limitations](#known-limitations).

Optional, order-independent **Phase 6** (wide-area/Tailscale remote access)
is deferred until a genuinely separate network exists to test from.

Read [`AGENTS.md`](AGENTS.md) before doing any further work in this repo —
it records binding pitfalls, a review checklist for verifying "done"
claims, and the full walkthrough for re-running the final E2E scenario.

## Documentation map

| Doc | Purpose |
|---|---|
| [`docs/INITIAL.md`](docs/INITIAL.md) | Authoritative implementation plan (source of truth) |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Condensed C4-model summary (Context/Container/Component) |
| [`docs/security.md`](docs/security.md) | Security posture, threat model, known limitations |
| [`docs/ai-coder.md`](docs/ai-coder.md) | Coder AI integration: entitlement matrix, repeatability model, MCP/CI automation (Issue #13) |
| [`docs/disaster-recovery.md`](docs/disaster-recovery.md) | Backup/restore runbook |
| [`docs/phases/`](docs/phases/README.md) | `INITIAL.md` split into 5 phases + milestones |
| [`docs/milestone-reports/`](docs/milestone-reports/) | Evidence report per completed milestone |
| [`docs/plan/demo/`](docs/plan/demo/) | Live, per-phase handover reports with fresh re-verification evidence |
| [`VERSION.md`](VERSION.md) | Release history |
| [`AGENTS.md`](AGENTS.md) | Agent-facing operational knowledge, lessons learned, full E2E walkthrough |

## Known limitations

- **`gh-aw`'s agentic CI-failure investigation cannot yet execute its
  reasoning step.** Its AWF sandbox requires a real Docker Unix socket,
  which is incompatible with this platform's socket-proxy-mediated
  self-hosted runner (by design, to avoid root-equivalent Docker access);
  no AI-engine credentials are provisioned either. Everything upstream
  (trigger wiring, permission scoping, network allowlisting, safe-outputs
  configuration, runner job pickup) is confirmed working. See
  `docs/security.md`.
- **VS Code Agent Host (AHP) session persistence requires a real VS Code
  Desktop GUI client** to drive — it cannot be exercised from a headless
  CLI-only environment (the Agent Host starts lazily on first interactive
  connection). The wiring and both verification scripts are confirmed
  working; see `docs/milestone-reports/M4-agent-host.md`.
- **OpenBao does not auto-unseal** across a container restart/recreate —
  rerun `make governance-bootstrap` whenever the `openbao` container is
  recreated.
- This is a **local/demo-scale deployment** (single Docker host, no HA, no
  paid cloud infrastructure) — it proves the architecture works, not that
  it is hardened for a multi-tenant production environment.
- The GitHub repository is currently **public**, which several
  self-hosted-runner safeguards (e.g. `gh-aw`'s integrity auto-filtering)
  are conditioned on; re-verify visibility before relying on those
  safeguards if the repo is ever made private.

## License

MIT — see [LICENSE](LICENSE).
