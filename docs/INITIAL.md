# Implementation Plan — Docker-First Private Developer Platform

## 1. Goal

Build a **single-repository, Docker-first private developer platform** that demonstrates the 2027-style development architecture discussed earlier:

- VS Code (or browser / CLI) as the human control surface
- **VS Code Agent Host + AHP (Agent Host Protocol) as a durable session plane**, independent of which client is attached
- persistent/remote agent sessions, with explicit memory and worktree isolation
- paid LLM access where desired
- Coder Community for remote development workspaces
- Docker + Dev Containers as the default execution environment
- GitHub Free as repository and coordination plane
- self-hosted GitHub Actions runner using outbound connectivity only
- GitHub Agentic Workflows (`gh-aw`) for repository-centric reasoning
- Temporal OSS for durable orchestration
- MCP/internal APIs for tools and context
- optional Keycloak, OpenBao, OPA, OpenTelemetry, and Grafana for governance and observability

See `docs/devenv-cloud.png` for the seven-layer reference diagram this plan implements.

The setup must:

1. Run primarily on **one Linux server**.
2. Be reproducible from **one Git repository**.
3. Require no paid infrastructure services.
4. Require no inbound Internet exposure for automation.
5. Use Docker wherever reasonably possible.
6. Allow later addition of GCP without redesigning the platform.
7. Include explicit validation milestones.
8. Require you, as the implementing agent, to perform manual end-to-end tests before proceeding to the next milestone.

---

# 2. Target Architecture

## 2.1 Seven-Layer Model

The platform is organized into seven layers (see `docs/devenv-cloud.png` for the full diagram):

```text
1. HUMAN CONTROL SURFACE
   VS Code / Browser / CLI
             │
             │ AHP (Agent Host Protocol)
             ▼
2. DURABLE SESSION PLANE
   VS Code Agent Host
   session state / chats / worktrees / approvals
             │
             ▼
3. AGENT / HARNESS PLANE
   GitHub Copilot / Claude / Gemini / OpenAI / OpenCode / Pi
             │
             ▼
4. DEVELOPMENT EXECUTION PLANE
   Coder Community
      ↓
   Docker workspace (Dev Containers / Podman / Incus VMs / Proxmox optional)
      ↓
   repo + buildchain + tools
             │
             ▼
5. COORDINATION / AUTOMATION
   GitHub
   ├─ Actions  → deterministic
   ├─ gh-aw    → reasoning
   └─ Temporal → durable processes
             │
             ▼
6. TOOL / CONTEXT FABRIC
   MCP / internal APIs / simulated lab API / docs & telemetry
             │
             ▼
7. GOVERNANCE / OPERATIONS
   identity (Keycloak) / secrets (OpenBao) / policy (OPA)
   network (Tailscale) / telemetry (OpenTelemetry, Grafana)
   backup / recovery
```

**The most important distinction in this model: Layer 2 (session persistence) and Layer 4 (workspace persistence) are not the same thing**, and neither is the same as Layer 5's durable orchestration (Temporal). Conflating these is the single biggest architectural mistake this plan originally made — see Section 2.2.

## 2.2 Three Durability Levels

```text
UI durability
VS Code closes
    ↓
AHP / Agent Host survives
    (client comes and goes; the Agent Host owns the session)

Workspace durability
workspace container restarts
    ↓
Coder persistent volume survives
    (the repo, toolchain state, and agent home directory survive a container replace)

Process durability
machine / worker crashes for hours
    ↓
Temporal survives
    (a durable workflow resumes exactly where it left off, state intact)
```

Do not assume that proving one durability level implies another. UI durability (AHP) proves the client is replaceable. Workspace durability (Coder) proves the execution environment survives a restart. Process durability (Temporal) proves long-running orchestration survives a worker crash. **All three must be tested independently** — see the Final Milestone (Section 22) Durability Boundary Tests.

## 2.3 Physical Deployment

```text
                          GitHub.com
                 repos / issues / PR / Actions
                            ▲
                            │
                  outbound HTTPS only
                            │
                            ▼
┌──────────────────────────────────────────────────────────┐
│                 PRIVATE LINUX SERVER                     │
│                                                          │
│  Docker Engine + Docker Compose                          │
│                                                          │
│  ┌─────────────┐   ┌─────────────┐                       │
│  │    Coder    │   │  Temporal   │                       │
│  │ Community   │   │    OSS      │                       │
│  └──────┬──────┘   └──────┬──────┘                       │
│         │                 │                              │
│         │                 ├── Temporal workers           │
│         │                 │                              │
│         ▼                 ▼                              │
│  ┌──────────────────────────────────────┐                │
│  │ Development / Agent Workspaces       │                │
│  │                                      │                │
│  │ repo + toolchain + VS Code Agent     │                │
│  │ Host (AHP) + agent CLI + tests       │                │
│  └──────────────────────────────────────┘                │
│                                                          │
│  ┌──────────────────────────────────────┐                │
│  │ GitHub Self-hosted Runner            │                │
│  │ outbound connection to GitHub        │                │
│  └──────────────┬───────────────────────┘                │
│                 │                                        │
│        ┌────────┼──────────────┐                         │
│        ▼        ▼              ▼                         │
│      Docker   Temporal       Local APIs                  │
│      builds   workflows      / lab simulation             │
│                                                          │
│  ┌─────────┐ ┌─────────┐ ┌─────┐ ┌───────────────┐      │
│  │OpenBao  │ │Keycloak │ │ OPA │ │ MCP services  │      │
│  └─────────┘ └─────────┘ └─────┘ └───────────────┘      │
│                                                          │
│  ┌───────────────────────────────────────────────┐       │
│  │ OpenTelemetry → Grafana                       │       │
│  └───────────────────────────────────────────────┘       │
│                                                          │
│  ┌───────────────────────────────────────────────┐       │
│  │ Artifact / Cache: OCI registry, sccache        │       │
│  └───────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────┘

                ▲
                │ AHP over SSH (Tailscale / LAN), or AHP over dev tunnel from browser
                │
       VS Code / Browser
```

Note: the diagram shows the target end-state after all milestones are complete. `OpenBao`, `Keycloak`, and `OPA` are not present until Milestone 12 and are added incrementally, not deployed alongside Coder/Temporal from the start — see Section 18 for their actual (deferred, partly optional) rollout order.

---

# 3. Core Architectural Rules

You, as the implementing agent, should follow these rules throughout the implementation.

## Rule 1 — Docker first, not Docker only

Use Docker for:

- Coder
- Temporal
- PostgreSQL
- GitHub runner
- MCP servers
- OpenBao
- Keycloak
- OPA
- OpenTelemetry
- Grafana
- development workspaces
- build environments
- agent runtimes
- artifact/cache services (registry, sccache)

Do not introduce Kubernetes, GCP, Incus, or Proxmox in the initial implementation.

Add a VM escape hatch later only if a real embedded workload requires:

- custom kernels
- USB/JTAG drivers
- PCI passthrough
- Windows
- nested virtualization
- hardware-specific kernel modules

---

## Rule 2 — One repository is the source of truth

A clean checkout of the repository plus local secrets must be sufficient to recreate the system.

Do not manually configure containers and then leave the configuration undocumented.

Any manual action must either:

- become a script, or
- be documented explicitly.

### Evidence standard for milestone reports

A screenshot alone is not sufficient proof. Every milestone report must include, alongside any screenshots:

- the exact command(s) run,
- the captured stdout/stderr (redirect with `| tee` or `> file.log`),
- the process exit code (`echo $?`),
- and a timestamp.

Save raw command logs under `docs/milestone-reports/<milestone>/` next to the report so results are independently reproducible and reviewable without relying on a rendered image.

---

## Rule 3 — Never commit secrets

Never commit:

- `.env`
- API keys
- GitHub PATs
- runner registration tokens
- Copilot/OpenAI/Claude/Gemini credentials
- OpenBao root/unseal secrets
- Coder session tokens
- private SSH keys

Commit only:

```text
.env.example
```

with placeholder values.

### Interim secret handling before Milestone 12 (OpenBao)

OpenBao is not deployed until Milestone 12, but the runner (M2), Coder workspaces (M3), the agent host (M4), and the agent/harness (M9) all require real credentials long before that. Until OpenBao exists:

- Store all real secrets in a local `.env` file with permissions `chmod 600`, never in tracked files.
- Reference `.env` values from `compose.yaml` only through `env_file:` / `${VAR}` interpolation — never hardcode a secret in a committed YAML file.
- Treat every credential introduced before M12 (GitHub runner registration token, Coder admin password, LLM API key) as temporary: rotate it once OpenBao is available in M12, and record the rotation in `docs/milestone-reports/M12-governance.md`.
- `scripts/doctor.sh` must fail loudly if it detects a secret-shaped string (e.g. `ghp_`, `sk-`) inside any tracked file, as an early regression guard.

---

## Rule 4 — GitHub remains the coordination plane

GitHub owns:

```text
Git
Issues
PRs
Actions
workflow state
agentic workflow triggers
```

The private server performs execution.

---

## Rule 5 — Different automation tools have different responsibilities

```text
GitHub Actions
    deterministic execution

gh-aw
    repository-centric reasoning

Temporal
    durable orchestration
```

Do not build one giant workflow system that tries to replace all three.

---

## Rule 6 — No arbitrary external access to the private server

Automation access:

```text
GitHub
   ↓
self-hosted runner
   ↓
private services
```

Interactive access:

```text
Laptop
   ↓
LAN / Tailscale
   ↓
AHP (over SSH or dev tunnel)
   ↓
VS Code Agent Host
   ↓
Coder workspace
```

Do not expose Docker, Temporal, OpenBao, Coder, or internal APIs directly to the public Internet.

---

## Rule 7 — Respect the three durability levels (Section 2.2)

Do not conflate:

- **UI durability** (AHP / Agent Host session survives closing VS Code) with
- **Workspace durability** (Coder persistent volume survives a container restart) with
- **Process durability** (Temporal survives a worker crash).

Each is validated by a different mechanism and a different test. A milestone that proves one does **not** imply the others pass. See M4 (AHP), M3/M6 (Coder persistence), and M8 (Temporal) for where each is validated individually, and the Final Milestone (Section 22) for the combined Durability Boundary Tests.

---

## Rule 8 — Agent session data stays local by default

VS Code's Agent Host can maintain searchable session history and, for some providers, optionally sync it to a cloud account. For this private platform:

```json
{
  "chat.sessionSync.enabled": false
}
```

must be the default in `.vscode/settings.json` / `agent-host/settings.json`. This is a deliberate choice, not an oversight: the goal is a self-controlled platform where session state (live session, local history, user/repository memory) stays on the private server unless a future milestone explicitly and intentionally enables sync.

---

# 4. Repository Structure

Create:

```text
private-dev-platform/
│
├── README.md
├── Makefile
├── compose.yaml
├── .env.example
├── .gitignore
├── VERSION.md
│
├── docs/
│   ├── architecture.md
│   ├── operations.md
│   ├── security.md
│   ├── disaster-recovery.md
│   └── milestone-reports/
│
├── scripts/
│   ├── doctor.sh
│   ├── bootstrap.sh
│   ├── wait-for-services.sh
│   ├── register-runner.sh
│   ├── unregister-runner.sh
│   ├── configure-coder-ssh.sh
│   ├── verify-agent-host.sh
│   ├── verify-ahp-session.sh
│   ├── create-agent-worktree.sh
│   ├── cleanup-agent-worktree.sh
│   ├── backup.sh
│   └── restore-test.sh
│
├── runner/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── README.md
│
├── coder/
│   ├── Dockerfile
│   ├── templates/
│   │   └── docker-workspace/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── README.md
│   └── examples/
│
├── agent-host/
│   ├── README.md
│   ├── settings.json
│   └── tests/
│       ├── persistence.md
│       └── handoff.md
│
├── sessions/
│   ├── README.md
│   └── worktree-policy.md
│
├── temporal/
│   ├── worker/
│   │   ├── Dockerfile
│   │   └── src/
│   ├── workflows/
│   └── README.md
│
├── cache/
│   ├── registry/
│   └── sccache/
│
├── mcp/
│   ├── docs-server/
│   └── lab-server/
│
├── governance/
│   ├── keycloak/
│   ├── openbao/
│   └── opa/
│
├── observability/
│   ├── otel/
│   └── grafana/
│
├── backup/
│   ├── backup-policy.md
│   └── restore-test.md
│
├── devcontainers/
│   └── base/
│       ├── devcontainer.json
│       └── Dockerfile
│
├── examples/
│   ├── hello-service/
│   │   ├── .devcontainer/
│   │   ├── src/
│   │   └── tests/
│   │
│   └── embedded-sim/
│       ├── .devcontainer/
│       ├── src/
│       ├── tests/
│       └── scripts/
│
├── .vscode/
│   ├── settings.json
│   └── extensions.json
│
└── .github/
    ├── workflows/
    │   ├── platform-ci.yml
    │   ├── runner-smoke.yml
    │   ├── durable-demo.yml
    │   └── local-capability.yml
    │
    └── agentic-workflows/
        └── investigate-failure.md
```

---

# 5. Standard Make Targets

You, as the implementing agent, must maintain these commands as the stable interface to the repository:

```bash
make doctor
make bootstrap
make up
make down
make status
make logs
make test
make runner-register
make runner-unregister
make coder-init
make agent-host-verify
make worktree-new
make worktree-cleanup
make cache-up
make e2e
make backup
make restore-test
```

A user should not need to memorize Docker Compose commands.

### Script test coverage

`make test` must include automated tests for the repository's own automation scripts (`doctor.sh`, `bootstrap.sh`, `wait-for-services.sh`, `register-runner.sh`, `unregister-runner.sh`, `configure-coder-ssh.sh`, `verify-agent-host.sh`, `verify-ahp-session.sh`, `create-agent-worktree.sh`, `cleanup-agent-worktree.sh`, `backup.sh`, `restore-test.sh`), not only the example applications. Use `shellcheck` for static analysis and `bats` (or an equivalent shell-testing framework) for behavioral tests covering at least: expected success path, missing-dependency failure path, and idempotency (running twice does not corrupt state). Do not treat these scripts as untested glue code — they are the operational core of the platform.

---

# 6. Milestone 0 — Host Preparation

## Objective

Establish a known-good Linux host.

Recommended baseline:

```text
Ubuntu LTS / Debian stable
x86-64
16 GB RAM minimum
32 GB recommended
100+ GB free disk
Docker Engine
Docker Compose plugin
Git
GNU Make
curl
jq
```

Do not install Kubernetes.

---

## Tasks

Create `scripts/doctor.sh`.

It must verify:

- Linux host
- architecture
- Docker available
- Docker daemon reachable
- Docker Compose available
- Git available
- curl available
- jq available
- enough disk space
- outbound HTTPS connectivity to GitHub
- ports required by the stack are available

Example expected behavior:

```bash
./scripts/doctor.sh
```

Output:

```text
[OK] Docker
[OK] Docker Compose
[OK] Git
[OK] outbound github.com connectivity
[OK] free disk: 312 GB
[OK] required ports
```

---

## Validation Milestone M0

Run:

```bash
make doctor
```

Acceptance criterion:

```text
all required checks = PASS
```

Do not continue otherwise.

---

## Manual E2E Test M0

You, as the implementing agent, must manually perform:

1. Reboot the server.
2. Log back in.
3. Run:

```bash
docker run --rm hello-world
```

4. Run:

```bash
git clone <platform-repository>
cd private-dev-platform
make doctor
```

5. Record the result in:

```text
docs/milestone-reports/M0-host.md
```

Include:

- OS version
- Docker version
- Compose version
- hostname
- CPU
- RAM
- free disk
- command output / exit codes showing PASS (per the evidence standard in Rule 2)

Only merge M0 after this report exists.

---

# 7. Milestone 1 — Compose Foundation

## Objective

Prove that the platform can be brought up and down predictably.

Initially include only:

```text
PostgreSQL (coder-db)
Coder
```

Temporal is **deliberately deferred to Milestone 8** — it is not needed until the durable-orchestration milestone, and standing it up here would add unnecessary footprint before it's used. Do not add governance or observability yet either.

---

## Compose Requirements

Every service must have:

- pinned image version
- explicit network
- named volume if persistent
- restart policy
- health check where supported

Create networks:

```text
platform-control
platform-workspaces
```

Do not use `network_mode: host`.

---

## Commands

Implement:

```bash
make up
make down
make status
make logs
```

`make up` should ultimately execute something equivalent to:

```bash
docker compose up -d
```

but hide implementation details from users.

---

## Validation Milestone M1

Run:

```bash
make up
make status
```

Verify:

```text
coder          healthy
coder-db       healthy
```

Then:

```bash
make down
make up
```

Verify all persistent data remains valid.

---

## Manual E2E Test M1

You, as the implementing agent, must:

1. Start the stack.
2. Open Coder UI in a browser.
3. Stop all containers:

```bash
make down
```

4. Start everything again:

```bash
make up
```

5. Confirm the UI returns.

Create:

```text
docs/milestone-reports/M1-compose.md
```

Record:

- commands
- screenshots/logs
- container status
- startup time
- restart result

---

# 8. Milestone 2 — Self-Hosted GitHub Runner

## Objective

Give GitHub an **outbound-only execution channel** into the private server.

This is strategically important because the server may have little or no inbound Internet accessibility.

Architecture:

```text
GitHub Actions
      │
      │ outbound runner connection
      ▼
private runner
      │
      ▼
local Docker / APIs
```

---

## Runner Requirements

Build the runner image in:

```text
runner/Dockerfile
```

Do not depend on an opaque third-party runner image.

The runner container should:

- download a pinned GitHub Actions Runner version
- persist runner configuration in a named volume
- connect outbound only
- use labels:

```text
self-hosted
linux
private-lab
docker
```

---

## Important Security Restriction

For the initial implementation:

```text
ONLY private repository workflows may target this runner.
```

This must be actively enforced, not merely stated as intent:

- Confirm and record repository visibility as `Private` in `docs/milestone-reports/M2-runner.md`.
- Do not enable this runner on any repository accepting external forks or contributions.
- Configure branch protection so `runner-smoke.yml` and any workflow targeting `[self-hosted, private-lab]` can only be triggered by collaborators with write access (`workflow_dispatch` restricted to the default branch, no `pull_request` trigger from forks).

Do not use:

```text
pull_request_target
```

with this runner, and do not add a `pull_request` trigger sourced from fork branches to any workflow that targets `[self-hosted, private-lab]`.

Do not mount `/var/run/docker.sock` directly into the runner container.

Direct Docker socket access is equivalent to unauthenticated root on the host: any workflow (including one introduced by a future mistake, dependency, or compromised action) can escape the container entirely. This must be mitigated, not merely documented.

Use one of the following instead, in order of preference:

1. **Rootless / isolated execution** — run job containers through `sysbox-runc` or a rootless Docker daemon so the runner can launch containers without host-level socket exposure.
2. **Docker-in-Docker (DinD) sidecar** — give the runner its own isolated Docker daemon (a `docker:dind` sidecar container) instead of the host socket, so a compromised job cannot reach host containers/volumes.
3. **Socket proxy** — if a proxy is unavoidable, put `docker-socket-proxy` (or equivalent) in front of the socket, allow-listing only the specific API calls the runner needs (e.g. `build`, `run` on approved images) and denying host-level operations (`exec` into arbitrary containers, volume mounts of host paths, `--privileged`).

If, after evaluating these options, direct socket access is still chosen for a specific milestone, this must be recorded as an explicit, time-boxed risk acceptance in `docs/security.md` — not silently accepted in this plan.

---

## GitHub Workflow

Create:

```text
.github/workflows/runner-smoke.yml
```

Manual trigger:

```yaml
workflow_dispatch:
```

Target:

```text
[self-hosted, private-lab]
```

The job should:

- print hostname
- print Docker version
- run an ephemeral test container
- call a local health endpoint

---

## Validation Milestone M2

From GitHub:

```text
Actions → runner-smoke → Run workflow
```

Expected result:

```text
PASS
```

The log must prove it executed on the private server.

---

## Manual E2E Test M2

This test must demonstrate the primary design requirement:

### Before the test

Confirm that the server has no intentionally opened inbound public port.

### Test

From another network or device:

1. Open GitHub.com.
2. Trigger `runner-smoke`.
3. Watch the workflow start.
4. Verify the job runs on the private server.
5. Verify the workflow calls a service available only inside the private environment.
6. Verify the result appears in GitHub.

Create:

```text
docs/milestone-reports/M2-runner.md
```

Explicitly answer:

```text
Can GitHub execute a controlled operation on the private server
without inbound access to the private server?
```

Expected answer:

```text
YES
```

---

# 9. Milestone 3 — Coder Development Workspace

## Objective

A developer must be able to request a development environment containing:

```text
Git checkout
toolchain
dependencies
build tools
VS Code remote support
```

without manually configuring a machine.

---

## First Workspace Type

Implement:

```text
docker-standard
```

using:

```text
Coder Community
+
Docker
+
Dev Container concepts
```

The workspace should automatically clone this same repository.

---

## Workspace Contents

Install at minimum:

```text
git
curl
build-essential
python
node or another simple runtime
GitHub CLI
Docker CLI if required
```

Use a project-specific non-root user.

---

## Example Application

Create:

```text
examples/hello-service/
```

It should support:

```bash
make build
make test
make run
```

inside the workspace.

The test suite may be tiny.

The purpose is proving the environment contract.

---

## Coder Template

`coder/templates/docker-workspace/` must:

1. create workspace container
2. mount persistent home volume
3. clone repository
4. start Coder agent
5. expose VS Code connection
6. start in project directory

This persistent home volume is also where Milestone 4's Agent Host state lives — see M4 for the exact directory layout. Do not treat the workspace container filesystem and the persistent home volume as interchangeable: only `/home/coder` (or equivalent) survives a container replace.

---

## Validation Milestone M3

From Coder:

```text
Create Workspace
→ docker-standard
```

Inside VS Code:

```bash
git status
make -C examples/hello-service build
make -C examples/hello-service test
```

Everything must pass without installing extra packages manually.

---

## Manual E2E Test M3

You, as the implementing agent, must:

1. Delete the existing workspace.
2. Create a completely fresh workspace.
3. Connect using VS Code.
4. Confirm the repository exists.
5. Build the sample.
6. Run tests.
7. Edit one line.
8. Commit the change on a test branch.
9. Push the branch to GitHub.

Record results in:

```text
docs/milestone-reports/M3-coder.md
```

The report must explicitly answer:

```text
Could a new developer become productive without configuring
the development environment manually?
```

Expected answer:

```text
YES
```

---

# 10. Milestone 4 — VS Code Agent Host + AHP

## Objective

Prove the **Durable Session Plane** (Layer 2) independently of both the workspace (Layer 4, Coder) and any specific LLM/agent harness (Layer 3, chosen in M9).

VS Code's Agent Host owns agent sessions independently of the UI client that's attached. Closing the editor window, reconnecting from another window, and the running host remaining the source of truth is the core property being validated here. Remote Agent Hosts communicate with clients through **AHP (Agent Host Protocol)**, typically over SSH or a dev tunnel.

You probably do not need to package your own Agent Host implementation — VS Code already bundles it. For a remote host, the Coder-provisioned workspace runs it as a standalone process, and VS Code installs/starts the required CLI when making a remote session connection.

**Important qualifier:** VS Code's own docs note that an active turn continues while the Agent Host remains running. Do not interpret AHP alone as "my agent survives deletion of its Docker workspace" — that is a *workspace* durability question (M3/M6, Coder's persistent volume), not a session durability question. See Rule 7 (Section 3) and Section 2.2.

---

## Bridge Coder Workspaces to AHP via SSH

Coder supports generating standard OpenSSH entries:

```bash
coder config-ssh
```

after which workspaces become reachable as normal SSH hosts, e.g. `ssh coder.my-workspace`. VS Code's Remote Agent Session feature explicitly supports AHP connections over SSH, so the connection path becomes:

```text
VS Code Agents window
       │
       │ AHP over SSH
       ▼
coder.<workspace-name>
       │
       ▼
VS Code Agent Host
       │
       ▼
repo / tools / terminal
```

Add `scripts/configure-coder-ssh.sh` to automate the `coder config-ssh` step and `scripts/verify-agent-host.sh` / `scripts/verify-ahp-session.sh` to check the Agent Host process is reachable over the configured SSH host.

---

## Persist the Agent Host's Workspace

The Coder Docker template's persistent home volume (M3) must explicitly include Agent Host state, not just the repo:

```text
Coder workspace container       ephemeral
│
├── /usr/local/toolchain         image
├── /usr/bin/...                 image
│
└── /home/coder                  persistent volume
    ├── project/
    ├── .config/
    ├── .cache/
    ├── .copilot/
    ├── .claude/
    └── agent/session state
```

Do not put the repository or agent session state purely into the ephemeral container filesystem — only the persistent volume survives a workspace container replace.

---

## Session Data Locality

Apply Rule 8 (Section 3) here: set `chat.sessionSync.enabled: false` in `agent-host/settings.json` / `.vscode/settings.json` so session history stays local to the private server rather than syncing to a cloud account by default.

---

## Coordinate Coder's Lifecycle with Active Agent Sessions

Coder supports automatic workspace stopping/scheduling, determining activity from IDE, SSH, terminal, and similar connections. There is no confirmed guarantee that VS Code Agent Host activity alone counts toward Coder's idle detection. This means a workspace could autostop while an agent is still working in the background, with no editor attached.

For the first implementation:

- Disable aggressive autostop on **agent-capable** workspaces specifically, while keeping a normal autostop policy (e.g. 4 hours) on human-only workspaces:

```text
human-only workspace:   autostop = 4 hours
agent-capable workspace: autostop = disabled / long
```

- Document this as a known limitation to revisit with a proper workspace lease later:

```text
Agent session starts
        │
        ▼
workspace lease ACTIVE
        │
agent finishes
        │
        ▼
workspace lease RELEASED
        │
        ▼
Coder may autostop
```

This is a small implementation detail with large reliability consequences — do not skip it.

---

## Validation Milestone M4

`scripts/verify-agent-host.sh` confirms the Agent Host process is running and reachable over the `coder config-ssh`-generated host, independent of any VS Code window being open.

---

## Manual E2E Test M4 (AHP Persistence)

This test was completely missing from the original plan.

You, as the implementing agent, must:

1. Create fresh Coder workspace.
2. Configure SSH: `coder config-ssh`.
3. Open VS Code Agents window.
4. Select the Coder SSH host.
5. Start an agent session.
6. Give the agent a task that takes long enough to observe (e.g. a multi-minute build).
7. Close the project VS Code window.
8. Wait.
9. Open the Agents window again.
10. Reconnect to the same host.
11. Confirm the same session remains available.
12. Confirm the agent continued while no editor window was attached.

This directly proves the architectural principle: **client comes and goes; Agent Host owns the session.**

Record in:

```text
docs/milestone-reports/M4-agent-host.md
```

---

# 11. Milestone 5 — Agent Session Persistence & Worktrees

## Objective

Session persistence and memory are different concepts from the AHP transport proven in M4. This milestone covers both **agent memory** (what the agent remembers across conversations) and **code isolation** (how multiple parallel agent sessions avoid clobbering each other's working tree).

Extend the Layer 2 model from:

```text
Durable Work Session
```

to:

```text
Durable Session & Memory Plane
AHP
Agent Host
session state
session history
repository memory
user memory
```

Do not put memory into Temporal — that's a different concern (durable orchestration, M8), not conversational/repository memory.

Both **user memory** and **repository memory** should live under the same persistent Coder home volume established in M4:

```text
persistent Coder home
│
└── VS Code agent memories
    ├── user
    └── repository
```

---

## Worktree Isolation for Parallel Sessions

If you want multiple parallel agents, they should not all arbitrarily mutate the same checkout:

```text
Agent session A
Agent session B
Agent session C
```

VS Code explicitly supports worktree-based agent sessions. A Git worktree is a **code isolation boundary, not a security sandbox** — do not treat it as one.

Structure the session plane as:

```text
Coder workspace
│
├── repo main checkout
│
├── worktree/session-001
│     └── Agent Host session A
│
├── worktree/session-002
│     └── Agent Host session B
│
└── worktree/session-003
      └── Agent Host session C
```

For the first implementation, use a simple rule:

```text
1 agent session = 1 worktree
```

Add `scripts/create-agent-worktree.sh` and `scripts/cleanup-agent-worktree.sh` to automate creation/teardown. Document the policy in `sessions/worktree-policy.md`.

---

## Validation Milestone M5

1. Start two agent sessions.
2. Have each modify the same file differently.
3. Confirm they're operating in separate worktrees.
4. Confirm neither silently overwrites the other's working tree.

---

## Manual E2E Test M5

You, as the implementing agent, must:

1. Create two agent worktrees via `scripts/create-agent-worktree.sh`.
2. Start an agent session in each.
3. Ask each session to edit the same file (e.g. append a different comment to the same line range).
4. Confirm both edits exist independently in their own worktree with no cross-contamination.
5. Clean up both worktrees via `scripts/cleanup-agent-worktree.sh` and confirm the main checkout is unaffected.
6. Separately, confirm repository memory persists: end a session, start a new one, and confirm the agent recalls prior repository-level notes without you re-explaining them.

Record in:

```text
docs/milestone-reports/M5-sessions.md
```

---

# 12. Milestone 6 — Embedded Simulation Workspace

## Objective

Prove that the same Coder/Docker model supports an embedded-style toolchain.

This milestone does **not** require physical hardware.

Use simulated tooling.

---

## Example

Create:

```text
examples/embedded-sim/
```

Possible toolchain:

```text
gcc
cmake
ninja
qemu-user or a small emulator
```

A simple example could:

1. compile a C application
2. execute tests
3. produce a firmware-like binary artifact
4. run a simulated target

Example:

```bash
make configure
make build
make test
make simulate
```

---

## Workspace Type

Create:

```text
embedded-linux
```

as a Docker workspace containing the full toolchain.

Do not require host package installation.

---

## Toolchain Provenance

The buildchain should not just be "latest ubuntu + random apt installs." Use:

```text
Dockerfile
→ pinned base
→ pinned tool versions
→ image digest
```

and eventually push it to the local OCI registry introduced in M7. This gives a workspace a reproducible identity:

```text
Repo revision
+
Dev Container revision
+
toolchain image digest
```

For embedded development specifically, this identity matters — a "works on my workspace" artifact should be traceable back to an exact image digest.

---

## Validation Milestone M6

Fresh workspace:

```text
embedded-linux
```

must successfully execute:

```bash
make -C examples/embedded-sim clean
make -C examples/embedded-sim build
make -C examples/embedded-sim test
make -C examples/embedded-sim simulate
```

---

## Manual E2E Test M6

Delete the workspace first.

Then:

```text
Coder → New Workspace → embedded-linux
```

Verify that a completely clean environment can produce the target artifact.

Record:

```text
artifact filename
compiler version
image digest
test output
simulation output
```

in:

```text
docs/milestone-reports/M6-embedded.md
```

---

# 13. Milestone 7 — Artifact Registry + Build Cache

## Objective

For embedded development especially, fresh workspaces are painful without caching: Docker images, toolchains, C/C++ compilation, and generated firmware all benefit from a persistent cache. This isn't a conceptual developer-facing layer on its own, but it's a missing infrastructure capability under Layer 4 (Development Execution Plane) that M6's reproducibility goal depends on for usable performance.

Add under Layer 4:

```text
Artifact / Cache Services
├── local OCI registry
├── BuildKit cache
├── sccache / ccache
└── persistent dependency caches
```

## Local OCI Registry

Use **CNCF Distribution** (Apache-2.0, self-hostable) for the local registry. Add:

```text
cache/registry/
```

and a `registry` service to compose.

## Compiler Cache

Use **sccache** (supports local and remote caches, suitable for compiler-heavy environments) for C/C++/Rust compilation caching. Add:

```text
cache/sccache/
```

Start with a persistent local sccache directory; a dedicated `sccache-storage` compose service is optional.

---

## Validation Milestone M7

1. Build `examples/embedded-sim` from a fresh workspace (cold cache) and record the build time.
2. Build it again from a second fresh workspace (warm cache via registry/sccache) and record the build time.
3. Confirm the second build is measurably faster and confirm cache hits in `sccache --show-stats` (or equivalent).

---

## Manual E2E Test M7

1. Delete any existing registry/cache volumes to guarantee a cold start.
2. Time a fresh `embedded-linux` workspace build (M6's example).
3. Delete the workspace (but not the cache volumes) and create a new one.
4. Time the build again.
5. Compare timings and cache-hit statistics.

Record in:

```text
docs/milestone-reports/M7-cache.md
```

---

# 14. Milestone 8 — Temporal Durable Workflow

## Objective

Prove durable orchestration (Layer 5) independently of GitHub agents and independently of the session/workspace durability proven in M4/M5/M6 (Rule 7, Section 3).

## Add Temporal to Compose

Add to the compose stack already running Coder + Coder-DB since M1:

```text
Temporal
Temporal-DB
Temporal UI
```

Apply the same Compose Requirements as M1 (pinned versions, explicit networks, named volumes, restart policy, health checks; no `network_mode: host`).

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

Then `make down && make up` and verify all persistent data (Coder + Temporal) remains valid. Update `docs/milestone-reports/M1-compose.md` with the Temporal addition.

## Durable Workflow

Implement a deliberately simple workflow:

```text
start
 ↓
activity A
 ↓
wait 30 seconds
 ↓
activity B
 ↓
finish
```

---

## Required Demonstration

The workflow must survive worker failure.

Example:

```text
Temporal
   │
   ├─ Activity: prepare_build
   │
   ├─ Timer: 30 seconds
   │
   └─ Activity: verify_build
```

---

## Validation Milestone M8

Start workflow.

During the timer:

```bash
docker compose stop temporal-worker
```

Wait several seconds, then:

```bash
docker compose start temporal-worker
```

Expected:

```text
workflow continues
workflow completes
workflow state not lost
```

---

## Manual E2E Test M8

You, as the implementing agent, must deliberately:

1. Start the durable demo.
2. Kill worker container (`docker compose kill temporal-worker`).
3. Restart the Temporal server component only (`docker compose restart temporal`) — do not reboot the host for this step.
4. Restart worker (`docker compose start temporal-worker`).
5. Verify workflow resumes.
6. Inspect Temporal UI history.

Record screenshots/logs and workflow ID in:

```text
docs/milestone-reports/M8-temporal.md
```

Explicitly answer:

```text
Did the process survive worker failure without manual state reconstruction?
```

Expected:

```text
YES
```

---

# 15. Milestone 9 — Agent/Harness Integration

## Objective

Introduce the Agent/Harness Plane (Layer 3) on top of the now-proven Session Plane (M4/M5) and Development Execution Plane (M3/M6).

## Local Agent Harness

This platform standardizes on two CLI-based agent harnesses, both already installed and confirmed working:

```text
opencode   (OpenCode CLI, v1.18.21)
pi         (Pi CLI, v0.84.2)
```

Install both into the agent workspace — this is not optional, since both are the supported harnesses for this platform. Test the Agent Test below with each. The harness software itself should remain replaceable at the interface level (each just needs to see repository context and call the same MCP/API surface later phases expose), and each should run through the AHP session plane established in M4/M5 rather than as a bare terminal process disconnected from that infrastructure.

## Backend Model Provider

Each CLI harness (`opencode`, `pi`) still needs a backend model/auth provider. Choose exactly one initial provider for the first pass:

```text
GitHub Copilot
OR
Claude
OR
OpenAI
OR
Gemini
```

Do not integrate four providers simultaneously. Recommended first option: **GitHub Copilot**, because GitHub is already the coordination plane (Rule 4).

---

## Agent Test

Create a deliberately failing unit test in a branch.

Ask the agent:

```text
Investigate why the test fails.
Do not modify code.
Return:
- root cause
- affected file
- recommended fix
```

---

## Validation Milestone M9

The model must:

- see repository context
- identify the known failure
- not require manual copying of the entire repository into chat

Run this test with **both** `opencode` and `pi` at least once, and record which one becomes the default harness for later milestones (M10's `gh-aw` and M11's agent-driven MCP calls should reuse whichever is chosen, unless there's a reason to keep both).

---

## Manual E2E Test M9

You, as the implementing agent, must:

1. Create fresh agent workspace (or worktree, per M5).
2. Authenticate the selected provider.
3. Intentionally break the sample project.
4. Ask the agent (`opencode` first, then `pi`) to diagnose it.
5. Compare the diagnosis with the known problem.
6. Save transcript/evidence for each CLI.

Record in:

```text
docs/milestone-reports/M9-agent.md
```

---

# 16. Milestone 10 — GitHub Agentic Workflows

## Objective

Add:

```text
gh-aw
```

without replacing normal Actions.

Architecture:

```text
GitHub event
    ↓
gh-aw
    ↓
reason
    ↓
safe decision
    ↓
deterministic workflow
```

`gh-aw`'s reasoning step should invoke the harness chosen in M9 (`opencode` or `pi`) where a local agent CLI is needed, rather than introducing a third tool.

---

## First Agentic Workflow

Create:

```text
.github/agentic-workflows/investigate-failure.md
```

It should:

1. inspect a failed Actions run
2. inspect relevant repository files
3. describe probable root cause
4. create a bounded output

Do not initially let it:

- deploy
- modify infrastructure
- control Docker host arbitrarily
- manipulate hardware

---

## Keep Deterministic Capabilities Separate

Example normal workflow:

```text
.github/workflows/local-capability.yml
```

This performs:

```text
build
test
simulation
```

The agent can request the capability, but should not reimplement the capability itself.

---

## Validation Milestone M10

Create known build failure.

Expected lifecycle:

```text
CI fails
 ↓
agentic workflow executes
 ↓
agent investigates
 ↓
result is visible in GitHub
```

---

## Manual E2E Test M10

You, as the implementing agent, must:

1. Introduce the documented test failure.
2. Push branch.
3. Observe deterministic CI fail.
4. Trigger or observe `gh-aw`.
5. Review agent reasoning.
6. Verify the agent did not perform unauthorized actions.

Record:

```text
docs/milestone-reports/M10-gh-aw.md
```

---

# 17. Milestone 11 — MCP and Local Capability Fabric

## Objective

Allow humans and agents to query private capabilities (Layer 6) without granting arbitrary shell access.

Implement two simple services.

---

## MCP Service 1 — Documentation

Provide tools such as:

```text
search_docs(query)
get_architecture()
get_build_instructions()
```

Populate it from local Markdown documentation.

---

## MCP/HTTP Service 2 — Lab Simulator

Do not use physical hardware yet.

Implement:

```text
list_devices()
reserve_device()
flash_device()
run_test()
get_logs()
release_device()
```

against simulated devices.

Example state:

```json
{
  "device": "ecu-demo-01",
  "status": "available"
}
```

---

## Validation Milestone M11

Agent (via the harness chosen in M9) should be able to answer:

```text
Which demo ECU is currently available,
and what build command should I use?
```

using the appropriate tool services.

---

## Manual E2E Test M11

Ask the agent to:

1. Query available simulated devices.
2. Reserve one.
3. Execute approved test operation.
4. Retrieve logs.
5. Release device.

Verify through service logs that calls happened through defined APIs rather than arbitrary host shell commands.

Record:

```text
docs/milestone-reports/M11-mcp.md
```

---

# 18. Milestone 12 — Governance Foundation

Do not build enterprise-scale security.

Implement enough to prove the architecture.

---

## OpenBao

Use for:

```text
LLM API secrets
demo device credentials
service credentials
```

No secret should need to appear in source code.

Once OpenBao is live, rotate every credential introduced during M2–M11 under the interim secret handling rule (Rule 3, Section 3) and record the rotation here.

---

## OPA

Implement at least three example policies:

```text
allow read_device
allow run_test
deny flash_device_without_approval
```

---

## Keycloak

Use only if identity experimentation is required.

Otherwise make this service optional through:

```text
docker compose --profile governance
```

---

## Validation Milestone M12

Attempt:

```text
run_test
```

Expected:

```text
ALLOW
```

Attempt:

```text
flash_device
```

without approval.

Expected:

```text
DENY
```

---

## Manual E2E Test M12

You, as the implementing agent, must intentionally try an unauthorized operation.

The test only passes if the system rejects it.

Record:

```text
docs/milestone-reports/M12-governance.md
```

Include the exact policy decision and the credential-rotation log for anything carried over from M2–M11.

---

# 19. Milestone 13 — Observability

## Objective

Make executions visible across:

```text
GitHub runner
Temporal worker
MCP service
lab simulation
Agent Host sessions
```

Deploy:

```text
OpenTelemetry Collector
Grafana OSS
```

Optional additional local backend:

```text
Prometheus
Loki
Tempo
```

Only add those if needed.

---

## Minimum Dashboard

Display:

```text
service uptime
Temporal activity count
MCP request count
lab API request count
workflow failures
```

---

## Validation Milestone M13

Execute:

```text
sample build
Temporal workflow
MCP request
```

All three must produce observable telemetry.

---

## Manual E2E Test M13

You, as the implementing agent, must:

1. Execute a complete local test.
2. Open Grafana.
3. Find the execution.
4. Correlate timestamps across services.

Record screenshots/logs in:

```text
docs/milestone-reports/M13-observability.md
```

---

# 20. Milestone 14 — Backup / Restore

## Objective

By this point the stack has state scattered across many services. This milestone was created in the original plan (`scripts/backup.sh`, `scripts/restore-test.sh`) but never actually validated with a real milestone. **A backup nobody has restored is not a backup strategy.**

## Classify State

```text
MUST BACK UP
platform repository
Coder database
Temporal database
OpenBao
important workspace state (persistent /home/coder, incl. agent memory/session state)

REPRODUCIBLE / DON'T NEED BACKUP
containers
Docker images you can rebuild
Dev Containers
toolchains generated from Dockerfiles
build caches (registry, sccache)
temporary agent worktrees
```

Document this classification in `backup/backup-policy.md`.

---

## Validation Milestone M14

1. Create workspace.
2. Create Temporal workflow.
3. Store test secret (in OpenBao, per M12).
4. Create agent/session data (per M4/M5).
5. Run `make backup`.
6. Destroy relevant containers/volumes (the "MUST BACK UP" set only).
7. Run `make restore-test` (or equivalent restore procedure).
8. Verify state: workspace, workflow, secret, and agent/session data are all recovered.

---

## Manual E2E Test M14

You, as the implementing agent, must personally run the 8-step sequence above against the real stack — not a dry run or a description of expected behavior. Confirm each of the four "MUST BACK UP" categories independently:

1. Repository/platform config restored.
2. Coder database restored (workspace metadata intact).
3. Temporal database restored (workflow history intact).
4. OpenBao restored (test secret still retrievable).
5. Persistent workspace home restored (agent memory/session state intact).

Record in `backup/restore-test.md` and:

```text
docs/milestone-reports/M14-backup.md
```

---

# 21. Milestone 15 — Remote Access / Browser Handoff

Automation already works without inbound access because the GitHub runner connects outbound (M2). This milestone covers **interactive** remote access, building on the AHP-over-SSH bridge established in M4.

Recommended:

```text
Tailscale Personal
```

Do not publicly expose Coder.

Target:

```text
Laptop
  │
Tailscale
  │
private server
  │
Coder
  │
workspace
```

---

## Validation Milestone M15

From a network outside the server LAN:

1. Connect through Tailscale.
2. Open Coder.
3. Connect VS Code.
4. Edit source.
5. Run build.

No public port forwarding should be required.

---

## Manual E2E Test M15

Use a mobile hotspot rather than the server's normal LAN. Confirm `VS Code → private Coder workspace` works.

Record:

```text
docs/milestone-reports/M15-remote.md
```

---

## Optional: Browser Agent Handoff Test

VS Code currently supports accessing remote Agent Host sessions from the browser through a dev tunnel. This is a stronger proof than SSH-based remote access alone, because it shows the **control surface itself** (not just the network path) is replaceable.

```text
VS Code desktop
     │
start session
     │
close desktop
     │
     ▼
browser Agents window
     │
same remote host
     │
same session
```

Mark this **optional** for the initial implementation — it introduces dev-tunnel authentication and another connectivity mechanism on top of what M15 already validates. Record results (if attempted) in `docs/milestone-reports/M15-remote.md` under a "Browser Handoff (optional)" subsection.

---

# 22. Final Milestone — Complete End-to-End Scenario

This is the most important acceptance test.

You, as the implementing agent, should not fake any step.

Use the simulated embedded project.

---

## Scenario

### Step 1 — Create problem

Create a GitHub issue:

```text
Embedded simulator regression: demo ECU validation failing
```

---

### Step 2 — Agent investigation

Trigger:

```text
gh-aw failure investigator
```

Agent must:

```text
inspect issue
inspect repository
inspect latest CI
reason about failure
```

---

### Step 3 — Deterministic local build

Agent or workflow invokes approved deterministic GitHub Action.

Execution:

```text
GitHub
 ↓
self-hosted runner
 ↓
Docker
 ↓
embedded build
```

---

### Step 4 — Start durable process

Workflow starts:

```text
Temporal validation workflow
```

Temporal must orchestrate:

```text
reserve simulated device
 ↓
wait
 ↓
run simulated test
 ↓
retrieve logs
```

---

### Step 5 — Capability call

Temporal activity calls:

```text
Lab / Device API
```

The API must go through policy checks.

---

### Step 6 — Simulated validation

Run:

```text
firmware artifact
+
simulated ECU
```

Return structured result.

---

### Step 7 — Agent evaluates output

Agent reads result and reports:

```text
failure cause
recommended fix
test evidence
```

---

### Step 8 — GitHub receives result

Result must appear in GitHub as one of:

```text
workflow summary
issue comment
PR comment
check result
```

---

# 23. Final Manual E2E Test Request

You, as the implementing agent, must execute this test personally.

No automated test is accepted as a substitute.

## Test Instructions

Start from a clean machine state:

```bash
make down
docker system prune
```

Do not delete persistent named volumes unless the test explicitly requires it.

Then:

### A. Start platform

```bash
make up
```

Verify health.

---

### B. Create fresh Coder workspace

```text
embedded-linux
```

Connect VS Code.

---

### C. Modify sample embedded code

Create a deliberate regression.

Commit and push branch.

---

### D. Observe GitHub CI

Normal deterministic CI should fail.

---

### E. Run agent investigation

Trigger `gh-aw`.

Verify meaningful diagnosis.

---

### F. Start approved local capability

Trigger the deterministic workflow.

Verify GitHub sends the job to:

```text
self-hosted private runner
```

---

### G. Verify private execution

On the server:

```bash
docker ps
```

Confirm the build/test workload actually ran locally.

---

### H. Verify durable orchestration

Start Temporal validation workflow.

During execution:

```bash
docker compose restart temporal-worker
```

Workflow must still complete.

---

### I. Verify tool fabric

Observe:

```text
Temporal
 ↓
Lab API
 ↓
simulated ECU
```

---

### J. Verify governance

Attempt one deliberately prohibited operation.

OPA must reject it.

---

### K. Verify observability

Find the test execution in Grafana/telemetry.

---

### L. Verify GitHub result

Final result must appear back in GitHub.

---

## Durability Boundary Tests

Steps A–L above prove the automation/coordination chain. These three additional tests prove the three durability levels from Section 2.2 individually — **do not assume proving one implies the others**.

### Durability Test 1 — UI failure (AHP)

```text
agent running
 ↓
close VS Code
 ↓
reopen
 ↓
same session continues
```

This is the same test as M4's Manual E2E Test, repeated here as part of the final combined proof. AHP validates this.

### Durability Test 2 — Worker failure (Temporal)

```text
Temporal workflow running
 ↓
kill worker
 ↓
restart
 ↓
workflow continues
```

This is the same test as M8's Manual E2E Test. Temporal validates this.

### Durability Test 3 — Workspace restart (Coder)

```text
Coder workspace
 ↓
stop
 ↓
start
 ↓
repo + persistent home survive
```

Coder validates this — Coder explicitly separates persistent resources (the home volume) from ephemeral workspace resources (the container). Do not assume Durability Test 1 (UI/AHP) passing means Durability Test 3 (workspace) automatically passes — that conflation was the central architectural gap in the original version of this plan.

---

# 24. Final Acceptance Criteria

The implementation is complete only if all of the following are true:

- [ ] Fresh clone can bootstrap the stack.
- [ ] No secret is committed.
- [ ] Docker Compose owns the platform lifecycle.
- [ ] GitHub self-hosted runner works without inbound public access.
- [ ] Coder can create a fresh Docker development workspace.
- [ ] Workspace automatically obtains repository source.
- [ ] Workspace contains a working custom build toolchain.
- [ ] VS Code can attach to the workspace.
- [ ] VS Code Agent Host session persists across editor close/reopen (AHP session survives UI disconnect) — Durability Test 1.
- [ ] Parallel agent sessions operate in isolated Git worktrees without overwriting each other.
- [ ] Coder workspace autostop does not terminate an active agent session.
- [ ] Both `opencode` and `pi` are installed in the workspace and have each successfully diagnosed a seeded failure.
- [ ] Normal GitHub Actions run deterministic CI.
- [ ] `gh-aw` performs repository-centric reasoning.
- [ ] Temporal survives worker interruption — Durability Test 2.
- [ ] Coder workspace restart preserves repo and persistent home — Durability Test 3.
- [ ] Local OCI registry + build cache measurably reduce fresh-workspace build time.
- [ ] MCP/internal APIs expose controlled capabilities.
- [ ] Simulated device operations work.
- [ ] OPA can deny an unsafe action.
- [ ] Secrets are not stored in source.
- [ ] Important execution events are observable.
- [ ] A full backup has been created and successfully restored, verified against every "MUST BACK UP" category.
- [ ] End-to-end flow begins in GitHub and returns a result to GitHub.
- [ ] Interactive access does not require public exposure of the server.
- [ ] All milestone reports are committed.

---

# 25. Development Workflow

Each milestone should use:

```text
main
 │
 └── milestone/M1-compose
 └── milestone/M2-runner
 └── milestone/M3-coder
 └── milestone/M4-agent-host
 ...
```

For every milestone:

1. create branch
2. implement only that milestone
3. run automated validation
4. execute manual E2E validation (personally, as the implementing agent)
5. create milestone report
6. open PR
7. review changes
8. merge only after acceptance criteria pass

Do not implement three milestones simultaneously.

---

# 26. Recommended Implementation Order

```text
M0  Host readiness
 ↓
M1  Docker Compose base (Coder only)
 ↓
M2  GitHub self-hosted runner
 ↓
M3  Coder workspace
 ↓
M4  VS Code Agent Host + AHP
 ↓
M5  Agent session persistence + worktrees
 ↓
M6  Embedded toolchain workspace
 ↓
M7  Artifact registry + build cache
 ↓
M8  Temporal durability
 ↓
M9  LLM / agent harness
 ↓
M10 gh-aw
 ↓
M11 MCP + Lab API
 ↓
M12 Governance
 ↓
M13 Observability
 ↓
M14 Backup / restore
 ↓
M15 Remote access / browser handoff
 ↓
FINAL E2E
```

**AHP (M4) is deliberately placed before the LLM/agent-harness milestone (M9).** First prove session infrastructure works, then prove intelligence inside that session works. Otherwise those two concerns get mixed together and a failure in one is hard to attribute to the right layer.

Do not start with the AI components.

First make:

```text
GitHub
+
Docker
+
Coder
+
runner
+
VS Code Agent Host
+
Temporal
```

boringly reliable.

Then add agents.

---

# 27. Versioning Policy

`VERSION.md` tracks the platform's release version, not individual milestones.

Milestones (M0–M15) are implementation stages, not releases. Do not tag or version-bump per milestone.

Rules:

- While any milestone from Section 6–21 is incomplete, the platform is pre-release. `VERSION.md` should read:

  ```text
  unreleased
  ```

- Once every checkbox in Section 24 (Final Acceptance Criteria) is checked and the Final Milestone (Section 22) end-to-end scenario — including the Durability Boundary Tests — passes, set:

  ```text
  0.1.0
  ```

- After `0.1.0`, use standard SemVer (`MAJOR.MINOR.PATCH`) for subsequent changes:

  ```text
  MAJOR — breaking change to the developer-facing contract (Make targets, repo layout, workspace types)
  MINOR — backward-compatible capability added (new workspace type, new MCP tool, new milestone-like feature)
  PATCH — bug fix, security patch, dependency bump with no behavior change
  ```

- Record every version bump as a dated entry in `VERSION.md` with a one-line summary of what changed.

---

# 28. Future GCP Extension

GCP should not be required for the initial implementation.

Later, preserve the same logical architecture:

```text
Coder
 │
 ├── local Docker workspace
 │
 └── GCP workspace
```

and:

```text
GitHub Actions
 │
 ├── private runner
 │
 └── GCP runner
```

and:

```text
Temporal
 │
 ├── local worker
 │
 └── GCP worker
```

The developer experience should remain:

```text
VS Code
 ↓
choose workspace
 ↓
work
```

The workflow should remain:

```text
GitHub
 ↓
reason / orchestrate / execute
 ↓
result
```

Cloud should therefore become **another execution location**, not another development platform.

---

# 29. Final Design Principle

The implementation should prove this corrected mental model:

```text
VS Code / Browser / CLI
       │
       │ AHP
       ▼
┌──────────────────────────┐
│ SESSION PLANE            │
│ Agent Host + AHP         │
│ chats / state / memory   │
│ worktrees                │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│ WORKSPACE PLANE          │
│ Coder                    │
│ Docker / Dev Container   │
│ repo / compiler / tools  │
│ persistent home          │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│ AUTOMATION PLANE         │
│ GitHub                   │
│ Actions / gh-aw          │
│ Temporal                 │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│ CAPABILITY PLANE         │
│ MCP / APIs / lab         │
└──────────────────────────┘

cross-cutting:
identity / policy / secrets
telemetry / cache / backup
```

The platform is successful when changing:

```text
local Docker
```

to:

```text
GCP
```

or changing:

```text
simulated ECU
```

to:

```text
real ECU
```

does **not** require redesigning the developer experience or coordination model.

The must-fix omissions that made this correction necessary were: AHP/session persistence being conflated with workspace persistence, missing parallel-session isolation (worktrees), a missing Coder/Agent-Host lifecycle coordination point (autostop vs. active sessions), and a missing backup/restore milestone. The local registry/build cache is a slightly less architectural addition, but for embedded development it's worth adding early — otherwise workspace reproducibility can be correct while startup/build performance is miserable.

That is the architecture the implementation should optimize for.
