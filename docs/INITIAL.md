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

See `docs/cade.png` for the seven-layer reference diagram this plan implements.

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

The platform is organized into seven layers (see `docs/cade.png` for the full diagram):

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

VS Code's `chat.sessionSync.enabled` setting **defaults to `true`**, syncing Copilot chat/session data to the user's GitHub.com account (this also requires `github.copilot.chat.localIndex.enabled`). For this private platform, that default must be explicitly overridden:

```json
{
  "chat.sessionSync.enabled": false
}
```

set in `.vscode/settings.json` / `agent-host/settings.json`. This is a deliberate override of VS Code's out-of-the-box behavior, not a description of what happens by default: the goal is a self-controlled platform where session state (live session, local history, user/repository memory) stays on the private server unless a future milestone explicitly and intentionally re-enables sync.

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
│   │   ├── docker-workspace/
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── README.md
│   │   ├── embedded-linux/
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── README.md
│   │   └── devcontainer/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── README.md
│   └── examples/
│
├── agent-host/
│   ├── README.md
│   ├── settings.json
│   ├── srt-settings.json
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
    └── workflows/
        ├── platform-ci.yml
        ├── runner-smoke.yml
        ├── durable-demo.yml
        ├── local-capability.yml
        ├── investigate-failure.md      # gh-aw source
        └── investigate-failure.lock.yml # gh-aw compiled (gh aw compile)
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
- outbound HTTPS connectivity to `update.code.visualstudio.com` and `vscode.download.prss.microsoft.com` (required by M4: VS Code's Agents window auto-installs a CLI binary plus a ~223 MB server bundle containing the Copilot harness on first remote connect — verified in the independent [`ahp-sandbox`](https://github.com/tbrandenburg/ahp-sandbox) POC; without this, M4's remote session simply never starts, with no GitHub-connectivity-shaped error to point at the real cause)
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

## Required Reading (before starting this milestone)

- Docker Compose in production: https://docs.docker.com/compose/how-tos/production/
- Dockerfile/image build best practices: https://docs.docker.com/build/building/best-practices/
- Coder security best practices (introduced here, deepened in M3): https://coder.com/docs/tutorials/best-practices/security-best-practices

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

## Required Reading (before starting this milestone)

- GitHub Actions security hardening (self-hosted runners section): https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions
- Dockerfile/image build best practices (applies to `runner/Dockerfile` specifically, not just the workspace images): https://docs.docker.com/build/building/best-practices/

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

Do not depend on an opaque third-party runner image. Pin the **base OS image by digest** (not just the GitHub Actions Runner tarball version) — this is the highest-security-sensitivity image in the whole plan (a privileged execution channel from GitHub into the private network), and deserves the same digest-pinning discipline as the M6/M7 toolchain images. Document a rebuild/patch cadence (e.g. monthly, or on CVE) in `docs/operations.md`. Keep the final image minimal — don't retain build-time-only packages (e.g. `curl`/`tar` used to fetch/extract the runner tarball) beyond what's needed at execution time, per Docker's multi-stage-build guidance, to reduce the blast radius of a compromised runner.

**Prefer Just-In-Time (JIT) / ephemeral runner registration over a long-lived persistent runner.** GitHub's own hardening guide recommends JIT runners (register via `--jitconfig`, run exactly one job, then auto-deregister) as the primary mitigation for runner-registration/persistence risk. `entrypoint.sh` should request a JIT config per job rather than registering once and persisting indefinitely; if a persistent runner is chosen instead for simplicity, record that as an explicit, time-boxed risk acceptance in `docs/security.md` (per the existing Docker-socket risk-acceptance pattern).

**Be aware of the `ps`-based secret leak risk**, also called out in GitHub's hardening guide: any secret passed as a CLI argument to a job process is visible to every other process on the same runner host via `ps x -w`. This is a stronger reason (beyond registration persistence) to prefer single-job/ephemeral runners — a shared, long-lived runner multiplies this exposure across unrelated jobs.

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

**This is not sufficient on its own.** Per GitHub's own "Security hardening for GitHub Actions" guidance, self-hosted runners "should almost never be used for public repositories," and even on a **private** repo, *any* collaborator who can open a pull request can compromise the runner if a workflow targeting `[self-hosted, private-lab]` is triggered by `pull_request` (not just `pull_request_target`) — this is broader than just avoiding the one dangerous trigger keyword. Restrict collaborators on this repository to fully trusted individuals, and gate every self-hosted-runner workflow behind `workflow_dispatch` (manual, explicit trigger) only — never an automatic `pull_request` trigger, regardless of trigger type.

Do not use:

```text
pull_request_target
```

with this runner, and do not add a `pull_request` trigger sourced from fork branches to any workflow that targets `[self-hosted, private-lab]`.

Do not mount `/var/run/docker.sock` directly into the runner container.

Direct Docker socket access is equivalent to unauthenticated root on the host: any workflow (including one introduced by a future mistake, dependency, or compromised action) can escape the container entirely. This must be mitigated, not merely documented.

Use one of the following instead, in order of preference:

1. **Rootless / isolated execution** — run job containers through `sysbox-runc` or a rootless Docker daemon so the runner can launch containers without host-level socket exposure.
2. **Docker-in-Docker (DinD) sidecar** — give the runner its own isolated Docker daemon (a `docker:dind` sidecar container) instead of the host socket, so a compromised job cannot reach host containers/volumes. **Caveat:** the standard `docker:dind` image commonly still needs `--privileged` on the sidecar itself unless it is paired with `sysbox-runc` (option 1) — a naive DinD sidecar is not automatically a lower-risk option than the socket proxy below; pair it with rootless/sysbox execution or it reintroduces a similar host-level risk on the sidecar container.
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

M9 later adds `bubblewrap`, `socat`, and `ripgrep` to this image to support sandboxing the agent CLIs with `srt` (Anthropic Sandbox Runtime) — see M9's "Sandbox Agent CLIs with Anthropic Sandbox Runtime (srt)" subsection for why and how.

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

**Template governance (per Coder's own security best practices):** push template revisions via `coder templates push` in CI, not manual admin-console edits, using a dedicated non-human Coder account — don't grant the Template Admin role broadly. Never inline provider credentials or other secrets directly in the Terraform template's `.tf`/`.tfvars` files: Coder does not obscure template file contents and **persists template versions indefinitely**, so a secret committed into a template revision stays recoverable even after being "fixed" in a later version. Pass credentials via `TF_VAR_*` environment variables or Coder parameters instead, consistent with Rule 3's `.env` handling.

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

## Required Reading (before starting this milestone)

- VS Code agent best practices: https://code.visualstudio.com/docs/agents/best-practices
- VS Code Agent Host concepts: https://code.visualstudio.com/docs/agents/concepts/agent-host
- VS Code agent security baseline (read in full — item #1 is directly required below): https://code.visualstudio.com/docs/agents/run/security
- Remote agent sessions (SSH/dev tunnel): https://code.visualstudio.com/docs/agents/run/remote-agent-sessions

## Objective

Prove the **Durable Session Plane** (Layer 2) independently of both the workspace (Layer 4, Coder) and any specific LLM/agent harness (Layer 3, chosen in M9).

VS Code's Agent Host owns agent sessions independently of the UI client that's attached. Closing the editor window, reconnecting from another window, and the running host remaining the source of truth is the core property being validated here. Remote Agent Hosts communicate with clients through **AHP (Agent Host Protocol)**, typically over SSH or a dev tunnel.

**Maturity note (verified against current VS Code/AHP docs):** this feature is real and works as described, but Microsoft's own documentation describes it as under active development, with new capabilities continuing to roll out. Treat the exact settings names, CLI flags, and behaviors as subject to change between VS Code releases — re-verify against `code.visualstudio.com/docs/agents` at implementation time rather than assuming this section is permanently accurate.

**Enable VS Code's own agent sandbox, not just `srt` (M9).** `chat.agent.sandbox.enabled` is the **#1 item** in VS Code's documented security-baseline checklist ("restrict file system and network access for agent-executed commands"), available on Linux/WSL2 — i.e. applicable to this Docker-based workspace. Set it in `agent-host/settings.json` as a first OS-level sandbox layer, complementary to (not a substitute for) the `srt` wrapping introduced in M9 — the two are independent controls and both should be enabled.

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

**Make `verify-ahp-session.sh` a real protocol check, not just a port/process check.** AHP is JSON-RPC over WebSocket on a plain HTTP-Upgrade endpoint (confirmed in the [`ahp-sandbox`](https://github.com/tbrandenburg/ahp-sandbox) POC, `docs/POC.md` step 7, without any VS Code GUI involved): a bare `curl` to the Agent Host port hangs (it isn't a normal HTTP server), but a `curl`/WebSocket client sending `Connection: Upgrade` gets `HTTP/1.1 101 Switching Protocols`, and a JSON-RPC `initialize` request with `params: {"protocolVersions":["1.0.0"]}` returns a real handshake response (`protocolVersion`, `serverSeq`, `defaultDirectory`, etc.). Script this handshake (curl + a small WebSocket client, e.g. Node's built-in `WebSocket`) instead of only checking that a process/port is listening — it's the difference between "something is listening" and "AHP actually answers."

**Verification note:** `coder config-ssh` and VS Code's SSH-based Agents window are each independently documented by their respective vendors (Coder and Microsoft), but no joint Coder+VS-Code-Agent-Host integration guide was found. This bridge is a composition of two independently-documented features that should work together (VS Code's remote-over-SSH path has no Coder-specific requirement beyond a working `sshd` in the workspace), not a vendor-blessed, jointly-tested integration — validate it carefully in M4's Manual E2E Test rather than assuming it's a documented, supported combination.

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
    ├── .vscode/cli/servers/Stable-<commit>/   # downloaded server bundle; contains the
    │                                          # Copilot harness itself (@github/copilot-linux-x64)
    ├── .vscode-server/cli/                     # supervisor log (agent-host-stable.log)
    ├── .vscode-server/data/                    # agent-host user-data-dir, logs/<timestamp>/
    └── agent/session state
```

**Verified paths (not a guess):** the two directories worth persisting are `~/.vscode` and `~/.vscode-server` as a pair — confirmed against a live Agent Host process tree in the independent [`ahp-sandbox`](https://github.com/tbrandenburg/ahp-sandbox) POC (`docs/POC.md`, steps 7 and 12). An earlier draft of this plan guessed a single `~/.vscode-cli` path, which does not exist; do not use it. Note also that the Copilot harness binary lives *inside* the `.vscode/cli/servers/.../server/node_modules/` tree, not in a separate `.copilot`-style directory — `.copilot`/`.claude` above are the CLI-tool config/credential dirs (M9), a different thing entirely.

Do not put the repository or agent session state purely into the ephemeral container filesystem — only the persistent volume survives a workspace container replace.

---

## Session Data Locality

Apply Rule 8 (Section 3) here: VS Code's `chat.sessionSync.enabled` defaults to `true` (syncing session data to the user's GitHub.com account) — this platform must explicitly override that default to `false` in `agent-host/settings.json` / `.vscode/settings.json` so session history stays on the private server instead.

---

## Coordinate Coder's Lifecycle with Active Agent Sessions

Coder's documented activity-detection list for autostop/scheduling purposes is: VS Code/JetBrains IDE sessions, web terminal, SSH sessions, and (separately) Coder's own "Tasks" feature for AI-agent working status. **A detached Agent Host process with no open IDE/SSH/terminal session is not on that list** — this platform is not using Coder Tasks, so a workspace **will** autostop while an agent works unattended unless autostop is disabled or a session (e.g. SSH) is deliberately kept open.

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

## Required Reading (before starting this milestone)

- QEMU User Mode Emulation docs (read the "System call translation" section to understand qemu-user's actual scope): https://www.qemu.org/docs/master/user/main.html

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

**Caveat:** `qemu-user` (user-mode emulation, e.g. `qemu-arm`) only emulates userspace/syscalls for a cross-compiled binary running against the target's libc — it does **not** emulate MMIO, interrupts, peripherals, or a boot process. It's a good fit for "compile → run → check exit code/stdout" (what this milestone needs), but it is not a hardware simulator and should not be described as validating real embedded/peripheral behavior. For genuinely bare-metal firmware (no libc/syscalls), use `qemu-system` with a machine model instead — hence "or a small emulator" as the documented alternative.

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

## Required Reading (before starting this milestone)

- CNCF Distribution deployment guide: https://distribution.github.io/distribution/about/deploying/
- sccache README (Known Caveats / `SCCACHE_BASEDIRS` sections): https://github.com/mozilla/sccache

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

**Do not run it as an open, unauthenticated registry reachable from the host network.** CNCF Distribution's own deployment guide states plainly: "a production-ready registry must be protected by TLS and should ideally use an access-control mechanism" — an unauthenticated local registry is otherwise a write-anywhere artifact store reachable from any container on the network. For this platform's scale, either (a) bind the registry only to the internal compose network with no host port published, or (b) enable basic auth (htpasswd) if it needs to be reachable more broadly. If a Docker healthcheck is added, note that an authenticated registry returns `401` (not `200`) from `/v2/` — a naive `curl -f` healthcheck will misreport it as unhealthy; check for `401` as the healthy response, or hit `/` instead.

## Compiler Cache

Use **sccache** (supports local and remote caches, suitable for compiler-heavy environments) for C/C++/Rust compilation caching. Add:

```text
cache/sccache/
```

Start with a persistent local sccache directory; a dedicated `sccache-storage` compose service is optional.

**Cache-key gotcha that would silently invalidate M7's own validation test:** sccache's cache keys include absolute file paths by default, so a cache hit requires the compiling workspace's absolute checkout path to match between runs. Since M7's validation explicitly builds from *two different* fresh workspace instances (cold vs. warm cache), if their absolute paths differ, sccache will **not** produce cache hits even with a warm registry/cache — silently invalidating the whole comparison. Set `SCCACHE_BASEDIRS` (or ensure both workspaces mount the project at an identical absolute path, e.g. `/workspace`) so path-based hashing doesn't defeat the cache across workspace instances.

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

## Required Reading (before starting this milestone)

- Temporal best practices index: https://docs.temporal.io/best-practices
- Worker deployment/performance: https://docs.temporal.io/best-practices/worker
- Error handling (idempotency, retries): https://docs.temporal.io/best-practices/error-handling
- Retry policy reference: https://docs.temporal.io/encyclopedia/retry-policies
- Self-hosted production checklist: https://docs.temporal.io/self-hosted-guide/production-checklist

## Objective

Prove durable orchestration (Layer 5) independently of GitHub agents and independently of the session/workspace durability proven in M4/M5/M6 (Rule 7, Section 3).

**Task Queue naming discipline is required, not optional:** Temporal's own worker best-practices doc warns that "a mismatch between the Client and Worker Task Queue names does not result in an error" — the workflow simply never gets picked up, silently. Define the Task Queue name (e.g. `demo-durable-workflow`) as a single shared constant referenced by both the workflow starter and the worker, not a hardcoded string duplicated in two places.

**Activities must declare a timeout.** Temporal SDKs require at least one timeout (e.g. `StartToCloseTimeout`) to be set on an Activity or it cannot be scheduled at all — this isn't just a best practice, it will be a hard error if omitted. Set an explicit `StartToCloseTimeout` (e.g. `30s`) on both `prepare_build` and `verify_build`.

**Activities must be idempotent.** Temporal's error-handling guide states Activities "may execute more than once due to retries" (e.g. a worker crash after an Activity completes but before Temporal receives the acknowledgment) and recommends an idempotency key derived from the Workflow Run ID + Activity ID. If `prepare_build`/`verify_build` write an artifact or mutate state, key that operation so a retried execution doesn't duplicate or corrupt it — this is also what makes M8's worker-kill test a meaningful proof rather than a lucky no-op.

## Add Temporal to Compose

Add to the compose stack already running Coder + Coder-DB since M1:

```text
Temporal
Temporal-DB (PostgreSQL, pin to a Temporal-supported major version, e.g. 13+)
Temporal UI
```

**Use the SQL-based visibility variant (no Elasticsearch/OpenSearch).** Temporal's own headline reference compose (`docker-compose.yml`) additionally requires Elasticsearch for its default visibility store — that is a 4th component this plan deliberately omits for lower operational overhead, using Postgres for both persistence and visibility instead (the SQL-visibility limitation — less advanced visibility search — is acceptable for this platform's scale). Use `temporalio/samples-server`'s `docker-compose-postgres.yml` as the reference (the older `temporalio/docker-compose` repo is archived; the reference examples now live under `samples-server`).

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

**Why this is safe:** a Timer is server-side state recorded in the workflow's Event History in Temporal-DB, not something the worker process holds in memory — killing the worker during the timer has no effect on the timer firing, because the Temporal Server (not the worker) tracks it. This only holds as long as the Temporal Server itself (and its database) stays up during the worker outage.

---

## Manual E2E Test M8

You, as the implementing agent, must deliberately:

1. Start the durable demo.
2. Kill worker container (`docker compose kill temporal-worker`).
3. Restart the Temporal server component only (`docker compose restart temporal`) — do not reboot the host for this step.
4. Restart worker (`docker compose start temporal-worker`).
5. Verify workflow resumes.
6. Inspect Temporal UI history.

**Note:** steps 2 and 3 test two different failure modes. Step 2 (worker kill/restart) proves the timer/workflow survives *worker* absence, because its state lives in Temporal-DB. Step 3 (restarting the `temporal` server component itself) is a *stronger*, separate proof — that the server process restarting doesn't lose state either, because state is durably persisted in Temporal-DB rather than in the server's memory. Do not treat these as one combined test; report on both independently.

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

## Required Reading (before starting this milestone)

- Anthropic Sandbox Runtime README (full configuration reference): https://github.com/anthropic-experimental/sandbox-runtime
- Claude Code sandboxing (same underlying primitives, deeper credentials-protection discussion): https://docs.claude.com/en/docs/claude-code/sandboxing
- VS Code agent security baseline (already required in M4 — re-confirm `chat.agent.sandbox.enabled` is set before adding `srt` on top of it): https://code.visualstudio.com/docs/agents/run/security

## Objective

Introduce the Agent/Harness Plane (Layer 3) on top of the now-proven Session Plane (M4/M5) and Development Execution Plane (M3/M6).

## Local Agent Harness

This platform standardizes on two CLI-based agent harnesses, both already installed and confirmed working:

```text
opencode   (OpenCode CLI, v1.18.21)
pi         (Pi CLI, v0.84.2)
```

Install both into the agent workspace — this is not optional, since both are the supported harnesses for this platform. Test the Agent Test below with each. The harness software itself should remain replaceable at the interface level (each just needs to see repository context and call the same MCP/API surface later phases expose).

**Known gap: `opencode`/`pi` do not run through AHP.** VS Code's Agent Host currently only bundles adapters for Copilot, Claude, and (experimental) Codex — `agent-host-protocol`'s only server implementation is VS Code's own, with no extension point for third-party CLIs to register as a host-side adapter. `opencode` and `pi` therefore run as plain terminal processes inside the workspace (wrapped by `srt`), not inside the Agent Host, so M4's AHP durability proof (session survives closing/reopening the editor) does not transfer to them. Re-verify against `code.visualstudio.com/docs/agents/run/agent-harnesses` at implementation time in case VS Code adds third-party AHP adapters later.

### Session Continuity Without AHP: `tmux`/`screen`

Give `opencode`/`pi` an equivalent property directly on the Coder workspace instead: a detached multiplexer session that keeps running whether or not a client (VS Code, SSH terminal) is attached, backed by the same persistent home volume as M4/M5.

```bash
# start (or reattach to) a named session for a given agent worktree
tmux new-session -A -s agent-session-001 -c ~/project/worktree/session-001

# inside it, run the wrapped harness as usual
opencode   # or: pi
```

- Name sessions after the worktree (M5's `1 agent session = 1 worktree` rule), e.g. `agent-session-001`, so `tmux ls` maps 1:1 to `worktree/session-NNN`.
- Install `tmux` in `coder/Dockerfile` alongside M9's `bubblewrap`/`socat`/`ripgrep`.
- Persist `~/.tmux` config (if any) under the M4 persistent home volume, not the ephemeral container filesystem.
- This proves **process continuity** (the agent keeps running, reconnect later) — not AHP's multi-client sync, remote handoff, or VS Code Agents-window session list. Don't conflate the two: it's a Coder-workspace property (M3/M4's volume + a live SSH host), same category as workspace durability, not a new instance of session-plane durability.
- Add `scripts/verify-agent-tmux-session.sh` (reattach after disconnect, confirm the wrapped harness process is still the same PID) alongside M4's `verify-ahp-session.sh`.

### Optional: Copilot as a Third, AHP-Native Harness

If a later requirement needs AHP's specific UX for `opencode`/`pi`-class interactive sessions (e.g. a non-technical reviewer watching/steering from the VS Code Agents window without SSH access, or cross-device handoff via M15's dev-tunnel bridge), add VS Code's built-in **Copilot** harness as a third, optional option rather than replacing `opencode`/`pi`:

- Copilot is the only harness (besides experimental Codex) that plugs directly into the Agent Host process, so it's the only one of the three that actually inherits M4's proven AHP durability out of the box — no `tmux` workaround needed.
- Credentials are close to free here: GitHub Copilot is already the recommended Backend Model Provider below, so the same GitHub auth context covers both the model backend and the Copilot harness.
- Keep `opencode`/`pi` as the standardized, automatable harnesses for the Agent Test below and M10's `gh-aw` (which needs a CLI engine, not VS Code's Agent Host) — Copilot-the-harness is additive for interactive AHP use cases, not a dependency of those milestones.
- Do not add it speculatively. Treat this as backlog until a concrete use case names the AHP-specific capability it needs; adding a third harness means a third credential store and a third `denyRead`/`srtAllowedDomains` entry to validate everywhere `~/.copilot` is already handled below.

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

### Zero-Configuration Starting Point: `opencode/big-pickle`

Before setting up any of the above paid providers, start with `opencode`'s built-in `opencode/big-pickle` model — it requires **no API key and no environment variable**:

```bash
opencode run --model opencode/big-pickle "Say hello in exactly 3 words."
```

Confirmed working with a completely clean environment (verified: no `ANTHROPIC_*`, `OPENAI_*`, `COPILOT_*`, `OPENCODE_*` API-key/token variables set). This makes it the right first thing to try when validating M9's mechanics (agent sees repo context, diagnoses a seeded failure) before spending time on provider authentication — get the harness plumbing proven with `big-pickle` first, then swap in the chosen paid provider above for production use. Note this is `opencode`-specific; `pi` still needs its own provider configured since it doesn't ship an equivalent no-auth default. (Note: this was confirmed via a direct manual test in this environment, not against `pi`'s or opencode's public documentation, since no authoritative public doc enumerating opencode's zero-config model catalog or pi's CLI reference was located during review — re-verify if either CLI's provider catalog changes.)

---

## Sandbox Agent CLIs with Anthropic Sandbox Runtime (srt)

Run `opencode` and `pi` wrapped in [Anthropic's Sandbox Runtime](https://github.com/anthropic-experimental/sandbox-runtime) (`srt`), an OS-level sandbox (no container-in-container needed) that enforces filesystem and network allowlists on the wrapped process tree. This is a defense-in-depth layer on top of the workspace container itself — the workspace already isolates the agent from the host (Rule 1), `srt` further isolates the agent from the rest of the workspace filesystem and from arbitrary network egress, so a compromised or misbehaving agent session cannot read `~/.ssh`, `.env`, or exfiltrate data to an arbitrary host even if it has a shell inside the workspace.

**Status:** this is a beta research preview from Anthropic, not a hardened production sandbox. Treat it as an additional layer, not a replacement for the workspace/runner isolation already required by Rule 1 and Rule 6.

### Installation

`srt` ships as an npm package and needs Node.js already present in the workspace image (already a requirement per M3's Workspace Contents):

```bash
npm install -g @anthropic-ai/sandbox-runtime
```

### Linux (workspace container) Preconditions

`srt` uses `bubblewrap` on Linux, not a container — it must be installed as an OS package **inside the workspace image**, alongside two more dependencies:

```dockerfile
# coder/Dockerfile (docker-standard workspace image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bubblewrap \
    socat \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*
```

- `bubblewrap` (`bwrap`) — the actual sandboxing primitive (user + network namespaces).
- `socat` — bridges the sandboxed process to the host-side proxy over a Unix domain socket.
- `ripgrep` (`rg`) — used internally for deny-path detection.

### Docker/Host Preconditions (nested sandboxing)

Because the workspace itself is already a Docker container, `srt`'s `bubblewrap` sandbox runs **nested inside** that container. This needs unprivileged user namespaces to be available at the container level, which depends on the **host** kernel, not just the workspace image:

1. Confirm the private server's host kernel allows unprivileged user namespaces:

   ```bash
   sysctl kernel.unprivileged_userns_clone
   ```

   If present and `0`, the host does not allow them by default; this must be enabled for `bwrap` to work inside any container on that host.

2. **Ubuntu 24.04+ hosts specifically** restrict unprivileged user namespaces via AppArmor by default, which blocks `bubblewrap` even if `unprivileged_userns_clone` is set. Disable the restriction on the host:

   ```bash
   sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
   ```

   (or install a scoped AppArmor profile that grants `userns` to `bwrap`/`node` instead of disabling the restriction system-wide — prefer this on a host that runs other untrusted workloads).

3. Smoke-test nested sandboxing from inside the workspace container before relying on it:

   ```bash
   bwrap --unshare-user --unshare-pid --ro-bind / / echo ok
   ```

   If this fails inside the Docker workspace even after the host-level fixes above, set `enableWeakerNestedSandbox: true` in `~/.srt-settings.json` (documented explicitly by `srt` as the flag for "Docker environments") rather than loosening the container's `seccomp`/`apparmor` profile broadly. Do not reach for `--privileged` or `--security-opt seccomp=unconfined` on the workspace container as a first fix — that weakens the Rule 1 container boundary itself, which is a bigger concession than nested-sandbox mode.

### Configuration

Version the template in the repo at `agent-host/srt-settings.json`, and have the Coder workspace startup script (or `configure-coder-ssh.sh`) copy/symlink it to `~/.srt-settings.json` inside the persistent Coder home volume (M4's persistent home layout) on first boot, so it survives a workspace container replace and stays under source control for review:

```json
{
  "network": {
    "allowedDomains": [
      "github.com",
      "*.github.com",
      "api.github.com",
      "copilot-proxy.githubusercontent.com"
    ],
    "deniedDomains": []
  },
  "filesystem": {
    "denyRead": ["~/.ssh", "~/.aws", ".env", "~/.claude", "~/.copilot"],
    "allowWrite": [".", "/tmp"],
    "denyWrite": [".env", "**/secrets/**"]
  },
  "enableWeakerNestedSandbox": false
}
```

**`denyRead` must include the agent's own credential stores.** M4's persistent home layout places `~/.claude` and `~/.copilot` (session tokens/credentials) inside the same `/home/coder` volume that `srt` is otherwise protecting — read access is allowed everywhere by default except what's explicitly denied, so if these paths aren't in `denyRead`, a sandboxed process can still read another provider's stored credentials even though `~/.ssh` is protected. Add both to `denyRead` as shown above, and add a check to M9's Manual E2E Test confirming a sandboxed session cannot read the *other* CLI's credential store (e.g. `opencode` sandboxed cannot read `~/.claude`'s token file).

Adjust `network.allowedDomains` to match whichever backend provider was chosen above (Copilot, Claude, OpenAI, or Gemini endpoints), and add the MCP/lab-simulator endpoints from M11 once that milestone exists.

### Wrapping the Harnesses

```bash
srt opencode -- <opencode args>
srt pi -- <pi args>
```

Alias these in the workspace shell profile (`/home/coder/.bashrc` or equivalent) so `opencode`/`pi` are sandboxed by default rather than opt-in:

```bash
alias opencode='srt opencode --'
alias pi='srt pi --'
```

### Validation

1. Confirm `bwrap --version`, `socat -V`, and `rg --version` all succeed inside the workspace.
2. Confirm `srt "cat ~/.ssh/id_rsa"` is blocked (`Operation not permitted`) while `srt "cat README.md"` succeeds.
3. Confirm `srt "curl <an allowed domain>"` succeeds while `srt "curl <a non-allowlisted domain>"` is blocked by the network allowlist.
4. Confirm `srt "cat ~/.claude/<credentials file>"` and `srt "cat ~/.copilot/<credentials file>"` are both blocked, so a sandboxed `opencode` session cannot read `pi`'s stored credentials (or vice versa).
5. Run the Agent Test below through the sandboxed alias and confirm the agent still functions normally against its allowlisted provider/MCP endpoints.

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

Additionally, confirm both harnesses run correctly through the `srt` sandbox wrapper (network/filesystem restrictions enforced, agent still functional against its allowlisted endpoints) before considering M9 complete.

---

## Manual E2E Test M9

You, as the implementing agent, must:

1. Create fresh agent workspace (or worktree, per M5).
2. Authenticate the selected provider.
3. Intentionally break the sample project.
4. Ask the agent (`opencode` first, then `pi`) to diagnose it — both wrapped in `srt`.
5. Compare the diagnosis with the known problem.
6. Save transcript/evidence for each CLI.
7. Separately, confirm the sandbox actually restricts the agent: attempt (via the agent or directly) to read `~/.ssh/id_rsa` and to reach a non-allowlisted domain, and confirm both are blocked by `srt`.

Record in:

```text
docs/milestone-reports/M9-agent.md
```

---

# 16. Milestone 10 — GitHub Agentic Workflows

## Required Reading (before starting this milestone)

- gh-aw architecture (security model, AWF network isolation): https://github.github.com/gh-aw/introduction/architecture/
- gh-aw safe outputs reference: https://github.github.com/gh-aw/reference/safe-outputs/
- gh-aw self-hosted runners reference (this platform's runner is self-hosted, not GitHub-hosted — read this before assuming the architecture doc's defaults apply as-is): https://github.github.com/gh-aw/reference/self-hosted-runners/

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

`gh-aw`'s reasoning step should invoke the harness chosen in M9 (`opencode` or `pi`) where a local agent CLI is needed, rather than introducing a third tool. `gh-aw` (`github/gh-aw`) explicitly supports GitHub Copilot, Claude Code, OpenAI Codex, Gemini, and **Pi** as engines — confirm the `pi` engine option against `gh-aw`'s current documentation when this milestone is implemented.

---

## First Agentic Workflow

`gh-aw` source files live in the **same directory as regular Actions workflows**, not a separate directory — create:

```text
.github/workflows/investigate-failure.md
```

Run `gh aw compile` to generate the executable sibling artifact:

```text
.github/workflows/investigate-failure.lock.yml
```

Commit **both** the `.md` source and the generated `.lock.yml` — Actions executes the compiled `.lock.yml`, not the Markdown source directly.

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

Enforce this with `gh-aw`'s documented **"safe outputs"** mechanism — a separate, permission-scoped job that applies only validated, allow-listed write operations (e.g. posting an issue comment) rather than letting the agentic step itself hold write permissions. Do not rely on the prose constraint above alone; wire it through safe outputs so it's enforced, not just requested.

**Also enforce, not just request, network and permission boundaries:**

- **Network egress allowlist (AWF):** since this runs on a self-hosted runner (not GitHub-hosted), an agent step with unrestricted network egress could exfiltrate data or reach internal-only services on the private server — a direct violation of Rule 6. Configure gh-aw's Agent Workflow Firewall in the workflow frontmatter (`network: { firewall: true, allowed: [...] }`), scoped to only the domains the investigation actually needs (e.g. GitHub API endpoints), not left unrestricted.
- **Minimal `permissions:` block:** explicitly declare `permissions: { contents: read }` (no `issues: write` etc.) in the workflow frontmatter rather than relying solely on safe-outputs' default read-only posture — this is a private repo, so gh-aw's public-repo `min-integrity: approved` auto-filtering doesn't apply here by default; be explicit instead of relying on an assumption that only holds for public repos.

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

## Required Reading (before starting this milestone)

- MCP security best practices (read "Local MCP Server Compromise" and "State Handle Hijacking" sections specifically): https://modelcontextprotocol.io/specification/draft/basic/security_best_practices

## Objective

Allow humans and agents to query private capabilities (Layer 6) without granting arbitrary shell access.

Implement two simple services. **Both must follow the transport-hardening guidance from the MCP spec's "Local MCP Server Compromise" section:** use `stdio` transport (spawned directly by the agent harness) wherever possible to limit access to just the calling client; if a service instead exposes HTTP for reuse across sessions, it must require a bearer token or bind to a Unix domain socket — never an open, unauthenticated TCP port.

---

## MCP Service 1 — Documentation

Provide tools such as:

```text
search_docs(query)
get_architecture()
get_build_instructions()
```

Populate it from local Markdown documentation. Use `stdio` transport (spawned by the agent harness) — this service has no reason to be network-reachable at all.

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

**Bind reservation tokens to the requesting caller.** Per the MCP spec's "State Handle Hijacking" guidance, `reserve_device()` returns a reservation identifier that is exactly the kind of server-issued state handle the spec warns must be bound server-side to the authenticated caller and never trusted as authentication by itself. `run_test()`, `get_logs()`, and `release_device()` must verify the calling session/agent identity matches the reservation's owner before acting — do not accept the reservation ID alone as sufficient authorization.

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

## Required Reading (before starting this milestone)

- OpenBao security model: https://openbao.org/docs/internals/security/
- Vault production hardening (conceptually applicable — OpenBao is a Vault fork with the same architecture; OpenBao has no separate hardening checklist of its own): https://developer.hashicorp.com/vault/docs/concepts/production-hardening
- OPA policy language / style: https://www.openpolicyagent.org/docs/policy-language
- OPA policy performance (indexing): https://www.openpolicyagent.org/docs/policy-performance
- Keycloak production configuration: https://www.keycloak.org/server/configuration-production
- Keycloak in containers: https://www.keycloak.org/server/containers

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

**Baseline hardening (both OpenBao's own security model and Vault's hardening guide treat these as non-negotiable):**

- **Configure TLS on the OpenBao listener** even for this local/demo deployment (a self-signed cert is acceptable). Both docs list eavesdropping as explicitly in-scope of the threat model — plain HTTP is not an acceptable default.
- **Revoke the initial root token after setup.** After `bao operator init`, configure auth methods and policies using the root token, then revoke it — do not leave it live long-term. Record where the unseal key shares (or the auto-unseal KMS key reference) are stored; they must not be committed to git, and this location must itself be covered by M14's backup plan (see M14's OpenBao snapshot/unseal-key note).

---

## OPA

Implement at least three example policies. These names describe the required *behavior*, not literal Rego syntax — actual Rego source is required alongside them, evaluated via OPA's decision API (`POST /v1/data/<package>/allow` etc.), e.g.:

```text
allow read_device
allow run_test
deny flash_device_without_approval
```

Example minimal Rego backing the above (adapt to real request shape):

```rego
package lab.authz

default allow := false

allow if {
    input.action == "read_device"
}

allow if {
    input.action == "run_test"
}

allow if {
    input.action == "flash_device"
    input.approved == true
}
```

The MCP lab-server (M11) queries OPA's decision endpoint before executing a privileged action and honors the `allow`/`deny` result — do not hardcode the allow/deny logic in the MCP server itself.

**Add `opa test` unit tests, not just manual/curl checks.** `opa test` is OPA's standard, expected mechanism for pinning policy behavior — the Validation Milestone below requires proving ALLOW/DENY outcomes, which a one-off manual check does not durably guarantee against regressions. Add `lab_authz_test.rego` covering: `run_test` (allow), `flash_device` with/without `approved` (allow/deny), and `read_device` (allow); run `opa test` as part of M12's validation, in addition to the manual E2E check.

---

## Keycloak

Use only if identity experimentation is required.

Otherwise make this service optional through:

```text
docker compose --profile governance
```

**If enabled, avoid Keycloak's own documented anti-pattern:** its production-configuration guide states plainly that `start-dev` "should be strictly avoided in production environments because it has insecure defaults." Use `start` (not `start-dev`) even for this demo, and set `KC_BOOTSTRAP_ADMIN_PASSWORD` from a generated/rotated secret rather than a hardcoded default password.

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

## Required Reading (before starting this milestone)

- OpenTelemetry Collector configuration best practices: https://opentelemetry.io/docs/security/config-best-practices/
- OpenTelemetry Collector hosting best practices: https://opentelemetry.io/docs/security/hosting-best-practices/
- Prometheus security model (read the opening warning about public exposure specifically): https://prometheus.io/docs/operating/security/
- Prometheus metric/label naming conventions: https://prometheus.io/docs/practices/naming/
- Grafana dashboard best practices: https://grafana.com/docs/grafana/latest/best-practices/

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
Prometheus       (REQUIRED — metrics storage backend)
Grafana OSS      (visualization only, queries Prometheus)
```

**Correction to the original assumption:** "OpenTelemetry Collector → Grafana" alone is **not** a complete pipeline. Grafana has no built-in ingestion or storage — a Grafana "data source" is a connection to a separate storage backend (Prometheus, Loki, Tempo, etc.); the Collector receives/processes/exports telemetry but does not serve queries itself. **Prometheus (metrics) is the minimum required backend**, not optional, for the Minimum Dashboard below to show anything at all.

**Binding and exposure — both mandatory, not optional:**

- **Bind the OTel Collector's receiver endpoints to the compose service hostname, not `0.0.0.0`**, and only publish ports actually needed by other containers on the compose network. OpenTelemetry's own config-best-practices doc names unrestricted-interface binding as a specific, tracked DoS-exposure risk (CWE-1327), with Docker Compose as one of its explicit examples. Also add a `memory_limiter` processor / bound `sending_queue.queue_size` so the Collector can't OOM while relaying telemetry from five services at once.
- **Never publish Prometheus's port to the host/public network.** Prometheus's security-model doc opens with an explicit, bolded warning that its HTTP endpoints "should not be exposed to publicly accessible networks." Keep it reachable only from Grafana and the Collector on the internal Docker network — this is the single most emphasized point in Prometheus's own security documentation.
- **Provision the Minimum Dashboard as version-controlled JSON**, not an ad hoc UI-created dashboard. Grafana's own best-practices doc lists dashboard-as-code as a baseline maturity practice, and this repo's own Rule 2 ("one repository is the source of truth") requires it anyway — put it at `observability/grafana/dashboards/phase4.json` (or equivalent) and provision it from file, not click-ops.

Additional backends, add only if genuinely needed for the Manual E2E Test's cross-service timestamp correlation:

```text
Loki   — if correlating log lines across services, not just metrics
Tempo  — if correlating distributed traces across services
```

Given M13's Manual E2E Test explicitly requires correlating timestamps *across* GitHub runner / Temporal worker / MCP service / lab simulation, Tempo (traces) is likely to be needed in practice, not just Prometheus — evaluate this once the pipeline is running rather than assuming metrics alone will suffice for cross-service correlation.

---

## Minimum Dashboard

Display (backed by Prometheus, at minimum):

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
Temporal database (including the Visibility store, if it uses a separate backend from the Persistence store — confirm this stack uses Postgres for both before assuming one pg_dump covers everything)
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

Document this classification in `backup/backup-policy.md`, including:

- **OpenBao backup mechanism:** use `bao operator raft snapshot save` (for Integrated Storage/Raft), not a raw filesystem/volume copy. Separately and securely back up the unseal keys (or the auto-unseal KMS key reference) — a restored OpenBao instance starts **sealed** and is unusable without them. `bao operator raft snapshot restore` is the corresponding restore command.
- **Coder workspace-home persistence is a *template* property, not an automatic platform guarantee.** Coder's own docs state resources are persistent only if the template follows specific practices (pinning the home volume to an immutable resource ID such as `coder_workspace.me.id`, and `lifecycle { ignore_changes = all }`). Verify the `docker-standard`/`embedded-linux` templates actually do this — a naively-written template can silently recreate (wipe) the "persistent" volume on workspace rebuild.

---

## Validation Milestone M14

1. Create workspace, and write a marker file with a unique, timestamped value into `/home/coder`.
2. Create Temporal workflow.
3. Store test secret (in OpenBao, per M12).
4. Create agent/session data (per M4/M5).
5. Run `make backup` (OpenBao via `bao operator raft snapshot save`; unseal keys/KMS reference backed up separately).
6. Destroy relevant containers/volumes (the "MUST BACK UP" set only).
7. Run `make restore-test` (OpenBao restore via `bao operator raft snapshot restore`, then unseal).
8. Verify state: workspace (assert the marker file exists with byte-for-byte identical content — do not treat "workspace starts" alone as sufficient evidence), workflow, secret, and agent/session data are all recovered.

---

## Manual E2E Test M14

You, as the implementing agent, must personally run the 8-step sequence above against the real stack — not a dry run or a description of expected behavior. Confirm each of the four "MUST BACK UP" categories independently:

1. Repository/platform config restored.
2. Coder database restored (workspace metadata intact).
3. Temporal database restored (workflow history intact, including Visibility store if separate).
4. OpenBao restored via raft snapshot restore, then successfully unsealed with the backed-up unseal keys/KMS reference, test secret still retrievable.
5. Persistent workspace home restored — verified via the exact marker-file content check from step 8 above, not just "workspace starts," since home-volume persistence depends on the Coder template being written correctly (immutable resource ID, `lifecycle { ignore_changes = all }`).

Record in `backup/restore-test.md` and:

```text
docs/milestone-reports/M14-backup.md
```

---

# 21. Milestone 15 — Remote Access / Browser Handoff

## Required Reading (before starting this milestone)

- Tailscale ACLs: https://tailscale.com/kb/1018/acls
- Tailscale SSH: https://tailscale.com/kb/1223/tailscale-ssh

Automation already works without inbound access because the GitHub runner connects outbound (M2). This milestone covers **interactive** remote access, building on the AHP-over-SSH bridge established in M4.

Recommended:

```text
Tailscale Personal
```

Do not publicly expose Coder.

**Configure an explicit least-privilege ACL — do not rely on Tailscale's default.** Tailscale's own ACL doc states: "in the absence of an `acls` section in the tailnet policy file, Tailscale applies the default allow all policy" — every device on the tailnet can reach every other device. That default contradicts this platform's own Rule 6 ("no arbitrary external access to the private server"). Write an explicit ACL restricting which tailnet devices/users can reach the private server's Coder/SSH ports, rather than leaving the tailnet-wide allow-all default in place. Also consider enabling device approval (manually approving new devices before they can send/receive traffic) — directly relevant to M15's own "mobile hotspot" test scenario, where a new/unfamiliar network context is connecting.

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

**This is a template property, not an automatic platform guarantee.** Coder's persistence model only holds if the workspace template pins the home volume to an immutable resource ID (e.g. `coder_workspace.me.id`, not a mutable attribute like `.name`/`.owner`) and sets `lifecycle { ignore_changes = all }` on it — a naively-written template can silently recreate (wipe) the volume on restart while still appearing to "work." Verify this test at the file-content level, not just "workspace starts": write a marker file with a unique, timestamped value before stopping the workspace, and assert the same file exists with byte-for-byte identical content after starting it again.

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
- [ ] Both `opencode` and `pi` run sandboxed via `srt` (Anthropic Sandbox Runtime) and VS Code's own `chat.agent.sandbox.enabled`, with a verified denied file read, a verified denied network destination, and verified cross-credential isolation.
- [ ] Self-hosted runner uses JIT/ephemeral registration (or has a documented time-boxed risk acceptance) and a digest-pinned, minimal base image.
- [ ] Normal GitHub Actions run deterministic CI.
- [ ] `gh-aw` performs repository-centric reasoning within an explicit network firewall allowlist and minimal `permissions:` block.
- [ ] Temporal survives worker interruption — Durability Test 2 — using a shared Task Queue constant, explicit Activity timeouts, and idempotent Activities.
- [ ] Coder workspace restart preserves repo and persistent home — Durability Test 3.
- [ ] Local OCI registry (auth-protected, no public port) + build cache (cache-key path issues addressed) measurably reduce fresh-workspace build time.
- [ ] MCP/internal APIs expose controlled capabilities over `stdio` or an authenticated/unix-socket transport, with reservation tokens bound to the requesting caller.
- [ ] Simulated device operations work.
- [ ] OPA can deny an unsafe action, backed by an `opa test` suite.
- [ ] OpenBao runs with TLS, revoked initial root token, and securely backed-up unseal keys.
- [ ] Secrets are not stored in source.
- [ ] Important execution events are observable via Prometheus (not exposed publicly) and a version-controlled Grafana dashboard.
- [ ] A full backup has been created and successfully restored, verified against every "MUST BACK UP" category.
- [ ] End-to-end flow begins in GitHub and returns a result to GitHub.
- [ ] Interactive access does not require public exposure of the server, and uses an explicit least-privilege Tailscale ACL rather than the allow-all default.
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
