# Phase 1 — Remote Dev Environment + Agent

## Phase Objective

Deliver a self-contained, demoable outcome with no dependency on GitHub automation, Temporal, or governance:

> From a laptop anywhere (mobile hotspot test), connect via Tailscale → AHP over SSH → VS Code Agent Host, into a Docker workspace with the repository auto-cloned, and have a working coding agent that can read repository context and diagnose a known failing test — with the session surviving closing and reopening the editor.

Milestones covered: **M0** (Host Preparation), **M1 — trimmed** (Compose Foundation: Coder only), **M3** (Coder Development Workspace), **M4** (VS Code Agent Host + AHP), **M5** (Agent Session Persistence & Worktrees), **M9** (LLM/Agent Harness Integration), **M15** (Remote Access / Browser Handoff).

Temporal/Temporal-DB are explicitly **deferred to Phase 3 (M8)** — nothing in Phase 1 needs durable orchestration, and skipping it here reduces RAM/disk footprint for an initial PoC.

**Why M4/M5 sit between M3 and M9:** the original plan jumped straight from "Coder workspace" to "LLM/agent harness," treating VS Code purely as an editor. That skipped an entire architectural layer — the Session Plane (AHP / VS Code Agent Host), which owns agent sessions independently of the workspace container or the UI client attached to it. M4 and M5 prove that layer on its own, before M9 puts an actual LLM behind it. See `docs/INITIAL.md` Section 2.2 (Three Durability Levels) and Rule 7 (Section 3) for why this distinction matters.

See `docs/INITIAL.md` Section 3 (Core Architectural Rules) and Section 4 (Repository Structure) for rules that apply across all phases.

## Required Reading (mandatory, before starting Phase 1)

Read these before touching the corresponding milestone — each is the official best-practices/security/hardening reference for a tool this phase introduces. `docs/INITIAL.md`'s per-milestone sections (linked below) also fold each doc's major recommendations directly into the plan; this list is for reading the primary source, not just the summary.

| Milestone | Tool | Required reading |
|---|---|---|
| M1 | Docker Compose | https://docs.docker.com/compose/how-tos/production/, https://docs.docker.com/build/building/best-practices/ |
| M3 | Coder | https://coder.com/docs/tutorials/best-practices/security-best-practices |
| M4 | VS Code Agent Host | https://code.visualstudio.com/docs/agents/best-practices, https://code.visualstudio.com/docs/agents/run/security, https://code.visualstudio.com/docs/agents/run/remote-agent-sessions |
| M9 | Anthropic Sandbox Runtime (`srt`) | https://github.com/anthropic-experimental/sandbox-runtime (README), https://docs.claude.com/en/docs/claude-code/sandboxing |
| M15 | Tailscale | https://tailscale.com/kb/1018/acls, https://tailscale.com/kb/1223/tailscale-ssh |

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

Prove that the Coder half of the platform can be brought up and down predictably. Temporal/Temporal-DB/Temporal-UI are **not** part of this phase — added in Phase 3, M8.

Initially include only:

```text
PostgreSQL (coder-db)
Coder
```

### Compose Requirements

Every service must have: pinned image version, explicit network, named volume if persistent, restart policy, health check where supported.

Create networks: `platform-control`, `platform-workspaces`. Do not use `network_mode: host`.

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

Verify: `coder healthy`, `coder-db healthy`. Then `make down && make up` and verify persistent data remains valid.

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

M9 later adds `bubblewrap`, `socat`, and `ripgrep` to this image to support sandboxing the agent CLIs with `srt` (Anthropic Sandbox Runtime).

### Example Application

Create `examples/hello-service/`, supporting `make build`, `make test`, `make run` inside the workspace. The test suite may be tiny — the purpose is proving the environment contract.

### Coder Template

`coder/templates/docker-workspace/` must: create workspace container, mount persistent home volume, clone repository, start Coder agent, expose VS Code connection, start in project directory.

This persistent home volume is also where M4's Agent Host state lives — see M4 for the exact directory layout. Only `/home/coder` (or equivalent) survives a container replace; the rest of the workspace container is ephemeral.

**Template governance (per Coder's own security best practices):** push template revisions via `coder templates push` in CI with a dedicated non-human account — don't grant Template Admin broadly, and never inline credentials in the Terraform template (Coder persists template versions indefinitely; a secret committed into one revision stays recoverable even after a later "fix"). Pass credentials via `TF_VAR_*` / Coder parameters instead.

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

## M4 — VS Code Agent Host + AHP

### Objective

Prove the **Durable Session Plane** independently of both the workspace (M3, Coder) and any specific LLM/agent harness (M9). VS Code's Agent Host owns agent sessions independently of the UI client attached — close the editor, reconnect from another window, and the running host remains the source of truth. Remote Agent Hosts communicate with clients through **AHP (Agent Host Protocol)**, typically over SSH or a dev tunnel.

You probably do not need to package your own Agent Host implementation — VS Code already bundles it. For a remote host, the Coder-provisioned workspace runs it as a standalone process, and VS Code installs/starts the required CLI when making a remote session connection.

**Important qualifier:** an active turn continues while the Agent Host remains running — this does **not** mean the agent survives deletion of its Docker workspace. That's a *workspace* durability question (M3/M6), not a session durability question. See `docs/INITIAL.md` Section 2.2 and Rule 7.

**Enable VS Code's own agent sandbox, not just `srt` (M9).** `chat.agent.sandbox.enabled` is item #1 in VS Code's documented security-baseline checklist and works on Linux/WSL2. Set it in `agent-host/settings.json` as a first OS-level sandbox layer, independent of and complementary to `srt` (introduced in M9) — both should be enabled, not one instead of the other.

### Bridge Coder Workspaces to AHP via SSH

```bash
coder config-ssh
```

Workspaces become reachable as normal SSH hosts (e.g. `ssh coder.my-workspace`). VS Code's Remote Agent Session feature supports AHP over SSH:

```text
VS Code Agents window → AHP over SSH → coder.<workspace-name> → VS Code Agent Host → repo / tools / terminal
```

Add `scripts/configure-coder-ssh.sh` to automate `coder config-ssh`, and `scripts/verify-agent-host.sh` / `scripts/verify-ahp-session.sh` to check the Agent Host process is reachable over the configured SSH host.

### Persist the Agent Host's Workspace

The persistent home volume from M3 must explicitly include Agent Host state, not just the repo:

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

Do not put the repository or agent session state purely into the ephemeral container filesystem.

### Session Data Locality

Set `chat.sessionSync.enabled: false` in `agent-host/settings.json` / `.vscode/settings.json` (Rule 8) — session history stays local to the private server by default.

### Coordinate Coder's Lifecycle with Active Agent Sessions

Coder's autostop/scheduling is driven by IDE/SSH/terminal activity; there's no confirmed guarantee that Agent Host activity alone counts toward idle detection. A workspace could autostop while an agent is still working with no editor attached.

For the first implementation: disable aggressive autostop on **agent-capable** workspaces specifically, while keeping normal autostop (e.g. 4 hours) on human-only workspaces. Document this as a known limitation to revisit with a proper workspace lease later.

### Validation Milestone M4

`scripts/verify-agent-host.sh` confirms the Agent Host process is running and reachable over the `coder config-ssh`-generated host, independent of any VS Code window being open.

### Manual E2E Test M4 (AHP Persistence)

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

Record in `docs/milestone-reports/M4-agent-host.md`.

---

## M5 — Agent Session Persistence & Worktrees

### Objective

Session persistence and memory are different concepts from the AHP transport proven in M4. This milestone covers **agent memory** (what the agent remembers across conversations) and **code isolation** (how multiple parallel agent sessions avoid clobbering each other's working tree).

Layer 2 becomes:

```text
Durable Session & Memory Plane
AHP
Agent Host
session state / session history
repository memory / user memory
```

Do not put memory into Temporal — that's a different concern (durable orchestration, M8). Both user and repository memory live under the same persistent Coder home volume established in M4.

### Worktree Isolation for Parallel Sessions

Parallel agent sessions should not all mutate the same checkout. A Git worktree is a **code isolation boundary, not a security sandbox**. Structure:

```text
Coder workspace
│
├── repo main checkout
│
├── worktree/session-001 → Agent Host session A
├── worktree/session-002 → Agent Host session B
└── worktree/session-003 → Agent Host session C
```

Simple rule for the first implementation: **1 agent session = 1 worktree**. Add `scripts/create-agent-worktree.sh` and `scripts/cleanup-agent-worktree.sh`. Document the policy in `sessions/worktree-policy.md`.

### Validation Milestone M5

1. Start two agent sessions.
2. Have each modify the same file differently.
3. Confirm they're operating in separate worktrees.
4. Confirm neither silently overwrites the other's working tree.

### Manual E2E Test M5

1. Create two agent worktrees via `scripts/create-agent-worktree.sh`.
2. Start an agent session in each.
3. Ask each session to edit the same file (e.g. append a different comment to the same line range).
4. Confirm both edits exist independently in their own worktree with no cross-contamination.
5. Clean up both worktrees via `scripts/cleanup-agent-worktree.sh` and confirm the main checkout is unaffected.
6. Confirm repository memory persists: end a session, start a new one, and confirm the agent recalls prior repository-level notes without you re-explaining them.

Record in `docs/milestone-reports/M5-sessions.md`.

---

## M9 — Agent/Harness Integration

### Objective

Introduce the Agent/Harness Plane on top of the now-proven Session Plane (M4/M5) and Development Execution Plane (M3), using the CLIs already installed and verified on this platform:

```text
opencode   (OpenCode CLI, v1.18.21)
pi         (Pi CLI, v0.84.2)
```

Install both into the agent workspace — not optional, since both are the supported harnesses for this platform. Each should run through the AHP session plane established in M4/M5 rather than as a bare terminal process disconnected from that infrastructure.

### Backend Model Provider

Choose exactly one initial provider for the first pass:

```text
GitHub Copilot
OR
Claude
OR
OpenAI
OR
Gemini
```

Do not integrate four providers simultaneously. Recommended first option: **GitHub Copilot**, because GitHub is already the coordination plane (Rule 4). Store the provider credential per the interim secret handling rule (Rule 3) — `.env` with `chmod 600`, never committed, rotated once OpenBao exists (Phase 4, M12).

### Zero-Configuration Starting Point: `opencode/big-pickle`

Before setting up any of the above paid providers, start with `opencode`'s built-in `opencode/big-pickle` model — it requires **no API key and no environment variable**:

```bash
opencode run --model opencode/big-pickle "Say hello in exactly 3 words."
```

Confirmed working with a completely clean environment (no `ANTHROPIC_*`, `OPENAI_*`, `COPILOT_*`, `OPENCODE_*` variables set). Use this to validate M9's mechanics (agent sees repo context, diagnoses a seeded failure) first, before spending setup time on provider authentication — then swap in the chosen paid provider above for production use. This is `opencode`-specific; `pi` still needs its own provider configured since it doesn't ship an equivalent no-auth default. (Note: this was confirmed via a direct manual test in this environment, not against `pi`'s or opencode's public documentation, since no authoritative public doc enumerating opencode's zero-config model catalog or pi's CLI reference was located during review — re-verify if either CLI's provider catalog changes.)

### Sandbox Agent CLIs with Anthropic Sandbox Runtime (srt)

Run `opencode` and `pi` wrapped in [Anthropic's Sandbox Runtime](https://github.com/anthropic-experimental/sandbox-runtime) (`srt`) — an OS-level sandbox (`bubblewrap` on Linux, no container-in-container) that enforces filesystem and network allowlists on the wrapped process tree. This is defense-in-depth on top of the workspace container itself: it stops a compromised or misbehaving agent session from reading `~/.ssh`/`.env` or exfiltrating to an arbitrary host, even with a shell inside the workspace. **Status:** beta research preview from Anthropic — an additional layer, not a replacement for the workspace/runner isolation already required by Rule 1/Rule 6.

**Install** (needs Node.js, already required by M3's Workspace Contents):

```bash
npm install -g @anthropic-ai/sandbox-runtime
```

**Workspace image preconditions** — add to `coder/Dockerfile`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    bubblewrap socat ripgrep \
    && rm -rf /var/lib/apt/lists/*
```

**Host/Docker nested-sandbox precondition** — `bubblewrap` runs nested inside the already-containerized workspace, which needs unprivileged user namespaces at the host kernel level:

1. Check `sysctl kernel.unprivileged_userns_clone` on the private server; must be `1`.
2. On **Ubuntu 24.04+ hosts**, AppArmor restricts unprivileged user namespaces by default even when the sysctl above is set — run `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` on the host (or install a scoped AppArmor profile granting `userns` to `bwrap`/`node` instead of a system-wide disable).
3. Smoke-test from inside the workspace: `bwrap --unshare-user --unshare-pid --ro-bind / / echo ok`. If it still fails after the host fixes above, set `"enableWeakerNestedSandbox": true` in `~/.srt-settings.json` (srt's documented flag for Docker environments) rather than loosening the workspace container's own `seccomp`/`apparmor` profile — do not reach for `--privileged` or `--security-opt seccomp=unconfined` on the workspace container as a first fix, since that weakens the Rule 1 container boundary itself.

**Configuration** — version the template at `agent-host/srt-settings.json` in the repo; have the workspace startup script copy/symlink it to `~/.srt-settings.json` in the persistent home volume (M4) on first boot:

```json
{
  "network": {
    "allowedDomains": ["github.com", "*.github.com", "api.github.com", "copilot-proxy.githubusercontent.com"],
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

**`denyRead` must include the agent's own credential stores.** M4's persistent home places `~/.claude` and `~/.copilot` inside the same volume `srt` otherwise protects — without adding both here, a sandboxed `opencode` session could still read `pi`'s stored credentials (or vice versa), since read access is allowed by default except what's explicitly denied.

Adjust `network.allowedDomains` to the chosen backend provider's endpoints, and extend with MCP/lab-simulator endpoints once Phase 3's M11 exists.

**Wrap the harnesses** by default via shell alias:

```bash
alias opencode='srt opencode --'
alias pi='srt pi --'
```

### Agent Test

Create a deliberately failing unit test in a branch. Ask the agent (via `opencode` or `pi`, sandboxed):

```text
Investigate why the test fails.
Do not modify code.
Return:
- root cause
- affected file
- recommended fix
```

### Validation Milestone M9

The model must see repository context, identify the known failure, and not require manual copying of the entire repository into chat.

Run this test with **both** `opencode` and `pi` at least once, and record which one becomes the default harness for later milestones (M10's `gh-aw`, M11's agent-driven MCP calls). Additionally, confirm both harnesses run correctly through the `srt` sandbox wrapper (restrictions enforced, agent still functional against allowlisted endpoints).

### Manual E2E Test M9

1. Create fresh agent workspace (or worktree, per M5).
2. Authenticate the selected provider.
3. Intentionally break the sample project.
4. Ask the agent (`opencode` first, then `pi`) to diagnose it — both wrapped in `srt`.
5. Compare the diagnosis with the known problem.
6. Save transcript/evidence for each CLI.
7. Confirm the sandbox actually restricts the agent: attempt to read `~/.ssh/id_rsa` and to reach a non-allowlisted domain, and confirm both are blocked by `srt`.
8. Confirm cross-credential isolation: a sandboxed `opencode` session cannot read `pi`'s credential store (`~/.copilot`) and vice versa.

Record in `docs/milestone-reports/M9-agent.md`.

---

## M15 — Remote Access / Browser Handoff

### Objective

Automation already works without inbound access once the GitHub runner exists (Phase 2), but Phase 1's deliverable is specifically the *interactive* remote path — pulled forward here because without it the workspace is only reachable on the local LAN, not "remote." This builds on the AHP-over-SSH bridge established in M4.

Recommended: **Tailscale Personal**. Do not publicly expose Coder.

**Configure an explicit least-privilege ACL — Tailscale's default is allow-all.** Without an `acls` section in the tailnet policy file, every device on the tailnet can reach every other device, which contradicts Rule 6. Write an ACL restricting access to the private server's Coder/SSH ports to only the devices/users that need it, and consider enabling device approval given M15's own "unfamiliar network" test scenario.

Target:

```text
Laptop → Tailscale → private server → Coder → workspace
```

### Validation Milestone M15

From a network outside the server LAN:

1. Connect through Tailscale.
2. Open Coder.
3. Connect VS Code.
4. Edit source.
5. Run build.

No public port forwarding should be required.

### Manual E2E Test M15

Use a mobile hotspot rather than the server's normal LAN. Confirm `VS Code → private Coder workspace` works.

Record in `docs/milestone-reports/M15-remote.md`.

### Optional: Browser Agent Handoff Test

VS Code supports accessing remote Agent Host sessions from the browser through a dev tunnel — a stronger proof than SSH-based remote access alone, since it shows the *control surface itself* (not just the network path) is replaceable:

```text
VS Code desktop → start session → close desktop → browser Agents window → same remote host → same session
```

Mark this **optional** for the initial implementation (dev-tunnel auth adds another connectivity mechanism). Record results, if attempted, in `docs/milestone-reports/M15-remote.md` under a "Browser Handoff (optional)" subsection.

---

## Phase 1 Manual E2E Testing (performed by you, the agent)

You, as the agent, must personally execute every Manual E2E Test in this phase (M0, M1, M3, M4, M5, M9, M15) end-to-end, without skipping, faking, or simulating any step. Automated validation (`make doctor`, `make status`, `scripts/verify-agent-host.sh`, etc.) is a precondition, not a substitute, for these manual walkthroughs. For each test:

- run it yourself against the real host/server, not a description of what should happen;
- capture command output, exit codes, and timestamps per the evidence standard (`docs/INITIAL.md` Section 3, Rule 2);
- for M4, actually close and reopen the VS Code window yourself and confirm the same Agent Host session continues — do not accept "it should work" as a substitute for reconnecting;
- for M5, actually run two parallel worktree sessions yourself and diff the files to confirm isolation;
- for M9, run the agent diagnosis test with both `opencode` and `pi` yourself, comparing your own diagnosis against the seeded known failure, and confirm the `srt` sandbox actually blocks a denied file read and a denied network destination;
- record the results in the corresponding `docs/milestone-reports/*.md` file before considering Phase 1 complete.

---

## Phase 1 Documentation & Agent Instructions Update

Before Phase 1 is considered done, you, as the agent, must:

1. **Update project docs** — create or update `docs/architecture.md` and `docs/operations.md` to reflect what actually got built (Coder + Coder-DB compose topology, `docker-standard` workspace contents, AHP/Agent Host bridge via `coder config-ssh`, worktree layout, Tailscale access path), not just what was planned. Fix any drift between `docs/INITIAL.md` / this phase file and the real implementation.
2. **Update `AGENTS.md`** at the repo root with:
   - **Guidelines** — any new binding rule discovered while building Phase 1 (e.g. workspace image sizing, Tailscale ACL quirks, Coder template gotchas, AHP/SSH connection quirks, autostop-vs-agent-session conflicts observed, `srt` nested-sandbox quirks on the host kernel).
   - **Agent Instructions** — concrete, current instructions for operating this repo with `opencode` and `pi`: how to open a workspace, how to bridge it via `coder config-ssh`, how each CLI authenticates, how to create/clean up a worktree, how to update `~/.srt-settings.json` allowlists when a new legitimate domain/path is needed, any flags or config needed to ground the agent in repo context.
   - **Lessons Learned** — a dated entry (`## Phase 1 — <date>`) describing what broke, what surprised you, and what to avoid next time. Do not overwrite prior entries; append.

Do not skip this step even if nothing "went wrong" — record confirmations as well as problems, so future phases know what's already solid.

---

## Phase 1 Exit Criteria

- [ ] `make doctor` passes on a fresh host.
- [ ] Coder + Coder-DB come up healthy via `make up` and survive `make down && make up`.
- [ ] A fresh `docker-standard` workspace auto-clones the repo, builds and tests `examples/hello-service` without manual setup.
- [ ] `coder config-ssh` bridges the workspace to a normal SSH host, and VS Code's Agents window connects via AHP over that SSH host.
- [ ] An agent session survives closing and reopening the VS Code window (Durability Test 1 from `docs/INITIAL.md` Section 23).
- [ ] Two parallel agent sessions operate in separate worktrees without overwriting each other's edits.
- [ ] Both `opencode` and `pi` are installed in the workspace and each has successfully diagnosed the seeded failing test, grounded in repo context, without manual copy-paste.
- [ ] `chat.agent.sandbox.enabled` is set in `agent-host/settings.json` (VS Code's own agent sandbox baseline, independent of `srt`).
- [ ] Both `opencode` and `pi` run wrapped in `srt` (Anthropic Sandbox Runtime), with a confirmed denied file read (`~/.ssh/id_rsa`), a confirmed denied network destination, and confirmed cross-credential isolation (`~/.claude`/`~/.copilot`), while remaining functional against their allowlisted endpoints.
- [ ] VS Code connects to the workspace over Tailscale from outside the server's LAN (mobile hotspot test), with an explicit least-privilege ACL in place (not Tailscale's allow-all default).
- [ ] `docs/milestone-reports/M0-host.md`, `M1-compose.md`, `M3-coder.md`, `M4-agent-host.md`, `M5-sessions.md`, `M9-agent.md`, `M15-remote.md` are all committed with command-level evidence.
- [ ] `docs/architecture.md` and `docs/operations.md` reflect the actual Phase 1 implementation.
- [ ] `AGENTS.md` has updated Guidelines, Agent Instructions, and a dated Phase 1 Lessons Learned entry.
