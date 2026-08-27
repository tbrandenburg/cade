# Phase 1 — Remote Dev Environment + Agent

## Phase Objective

Deliver a self-contained, demoable outcome with no dependency on GitHub automation, Temporal, or governance:

> From a laptop anywhere (mobile hotspot test), connect via Tailscale → Coder → VS Code, into a Docker workspace with the repository auto-cloned, and have a working coding agent that can read repository context and diagnose a known failing test.

Milestones covered: **M0** (Host Preparation), **M1 — trimmed** (Compose Foundation: Coder only), **M3** (Coder Development Workspace), **M6 — fixed** (Agent/Harness Integration), **M11** (Remote Interactive Access).

Temporal/Temporal-DB are explicitly **deferred to Phase 3** — nothing in Phase 1 needs durable orchestration, and skipping it here reduces RAM/disk footprint for an initial PoC.

See `docs/INITIAL.md` Section 3 (Core Architectural Rules) and Section 4 (Repository Structure) for rules that apply across all phases.

---

## M0 — Host Preparation

### Objective

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

### Tasks

Create `scripts/doctor.sh`. It must verify:

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

### Validation Milestone M0

```bash
make doctor
```

Acceptance criterion: all required checks = PASS. Do not continue otherwise.

### Manual E2E Test M0

1. Reboot the server.
2. Log back in.
3. `docker run --rm hello-world`
4. `git clone <platform-repository> && cd private-dev-platform && make doctor`
5. Record the result in `docs/milestone-reports/M0-host.md`, including OS version, Docker version, Compose version, hostname, CPU, RAM, free disk, and command output/exit codes per the evidence standard in Section 3 Rule 2.

Only merge M0 after this report exists.

---

## M1 (trimmed) — Compose Foundation: Coder only

### Objective

Prove that the Coder half of the platform can be brought up and down predictably. Temporal/Temporal-DB/Temporal-UI are **not** part of this phase — add them in Phase 3.

Initially include only:

```text
PostgreSQL (coder-db)
Coder
```

Do not add Temporal, governance, or observability yet.

### Compose Requirements

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

### Commands

```bash
make up
make down
make status
make logs
```

`make up` should ultimately execute something equivalent to `docker compose up -d` but hide implementation details from users.

### Validation Milestone M1 (trimmed)

```bash
make up
make status
```

Verify:

```text
coder          healthy
coder-db       healthy
```

Then `make down && make up` and verify persistent data remains valid.

### Manual E2E Test M1 (trimmed)

1. Start the stack.
2. Open Coder UI in a browser.
3. `make down`
4. `make up`
5. Confirm the UI returns.

Record in `docs/milestone-reports/M1-compose.md`: commands, screenshots/logs, container status, startup time, restart result.

---

## M3 — Coder Development Workspace

### Objective

A developer must be able to request a development environment containing git checkout, toolchain, dependencies, build tools, and VS Code remote support — without manually configuring a machine.

### First Workspace Type

Implement `docker-standard` using Coder Community + Docker + Dev Container concepts. The workspace should automatically clone this same repository.

### Workspace Contents

Install at minimum: `git`, `curl`, `build-essential`, `python`, `node` (or another simple runtime), GitHub CLI, Docker CLI if required. Use a project-specific non-root user.

### Example Application

Create `examples/hello-service/`, supporting `make build`, `make test`, `make run` inside the workspace. The test suite may be tiny — the purpose is proving the environment contract.

### Coder Template

`coder/templates/docker-workspace/` must: create workspace container, mount persistent home volume, clone repository, start Coder agent, expose VS Code connection, start in project directory.

### Validation Milestone M3

From Coder: `Create Workspace → docker-standard`. Inside VS Code:

```bash
git status
make -C examples/hello-service build
make -C examples/hello-service test
```

Everything must pass without installing extra packages manually.

### Manual E2E Test M3

1. Delete the existing workspace.
2. Create a completely fresh workspace.
3. Connect using VS Code.
4. Confirm the repository exists.
5. Build the sample.
6. Run tests.
7. Edit one line.
8. Commit the change on a test branch.
9. Push the branch to GitHub.

Record results in `docs/milestone-reports/M3-coder.md`. The report must explicitly answer: *"Could a new developer become productive without configuring the development environment manually?"* Expected answer: YES.

---

## M6 (fixed) — Agent/Harness Integration

### Objective

Introduce a coding agent harness inside the workspace, using the CLIs already installed and verified on this platform:

```text
opencode   (OpenCode CLI)
pi         (Pi CLI)
```

Both are already installed and confirmed working:

```bash
opencode --version   # 1.18.21
pi --version          # 0.84.2
```

Install both into the `docker-standard` workspace image (not "optionally," as originally drafted — they are the two supported harnesses for this platform, and both should be present so either can be used or compared). The harness software itself remains replaceable; do not hard-couple the platform to either CLI's internals.

### Backend Model Provider

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

Store the provider credential per the interim secret handling rule in `docs/INITIAL.md` Section 3 (Rule 3) — `.env` with `chmod 600`, never committed, rotated once OpenBao exists (Phase 4).

### Agent Test

Create a deliberately failing unit test in a branch. Ask the agent (via `opencode` or `pi`, whichever is under test):

```text
Investigate why the test fails.
Do not modify code.
Return:
- root cause
- affected file
- recommended fix
```

### Validation Milestone M6

The model must:

- see repository context
- identify the known failure
- not require manual copying of the entire repository into chat

Run this test with **both** `opencode` and `pi` at least once, and record which one becomes the default harness for later phases (Phase 2's `gh-aw` and Phase 3's agent-driven MCP calls should reuse whichever is chosen, unless there's a reason to keep both).

### Manual E2E Test M6

1. Create fresh agent workspace.
2. Authenticate the selected provider.
3. Intentionally break the sample project.
4. Ask the agent (`opencode` first, then `pi`) to diagnose it.
5. Compare the diagnosis with the known problem.
6. Save transcript/evidence for each CLI.

Record in `docs/milestone-reports/M6-agent.md`.

---

## M11 — Remote Interactive Access

### Objective

Automation already works without inbound access once the GitHub runner exists (Phase 2), but Phase 1's deliverable is specifically the *interactive* remote path — pulled forward here because without it the workspace is only reachable on the local LAN, not "remote."

Recommended: **Tailscale Personal**. Do not publicly expose Coder.

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

### Validation Milestone M11

From a network outside the server LAN:

1. Connect through Tailscale.
2. Open Coder.
3. Connect VS Code.
4. Edit source.
5. Run build.

No public port forwarding should be required.

### Manual E2E Test M11

Use a mobile hotspot rather than the server's normal LAN. Confirm `VS Code → private Coder workspace` works.

Record in `docs/milestone-reports/M11-remote.md`.

---

## Phase 1 Exit Criteria

- [ ] `make doctor` passes on a fresh host.
- [ ] Coder + Coder-DB come up healthy via `make up` and survive `make down && make up`.
- [ ] A fresh `docker-standard` workspace auto-clones the repo, builds and tests `examples/hello-service` without manual setup.
- [ ] Both `opencode` and `pi` are installed in the workspace and each has successfully diagnosed the seeded failing test, grounded in repo context, without manual copy-paste.
- [ ] VS Code connects to the workspace over Tailscale from outside the server's LAN (mobile hotspot test).
- [ ] `docs/milestone-reports/M0-host.md`, `M1-compose.md`, `M3-coder.md`, `M6-agent.md`, `M11-remote.md` are all committed with command-level evidence.
