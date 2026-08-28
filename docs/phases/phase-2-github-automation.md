# Phase 2 — GitHub Automation Backbone

## Phase Objective

Prove that GitHub can trigger deterministic CI and repository-centric agent reasoning on the private server, using an outbound-only connection — independent of Phase 1's interactive workspace.

Milestones covered: **M2** (Self-Hosted GitHub Runner), **M10** (GitHub Agentic Workflows).

Depends on Phase 1 only for the agent harness existing (`opencode`/`pi` chosen as default in M9); does not depend on Coder workspaces or the Session Plane (M4/M5) being up.

## Required Reading (mandatory, before starting Phase 2)

| Milestone | Tool | Required reading |
|---|---|---|
| M2 | GitHub Actions self-hosted runners | https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions, https://docs.docker.com/build/building/best-practices/ |
| M10 | gh-aw | https://github.github.com/gh-aw/introduction/architecture/, https://github.github.com/gh-aw/reference/safe-outputs/, https://github.github.com/gh-aw/reference/self-hosted-runners/ |

---

## M2 — Self-Hosted GitHub Runner

### Objective

Give GitHub an **outbound-only execution channel** into the private server. Strategically important because the server may have little or no inbound Internet accessibility.

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

### Runner Requirements

Build the runner image in `runner/Dockerfile`. Do not depend on an opaque third-party runner image. Pin the base OS image by digest (this is the highest-security-sensitivity image in the plan) and document a rebuild/patch cadence in `docs/operations.md`; keep the final image minimal (no unnecessary build-time-only packages). If the build host sits behind a corporate/TLS-intercepting proxy, apply the same optional `CACERT`/BuildKit-secret pattern documented in Phase 1's M3 (`coder/Dockerfile`) rather than inventing a second mechanism. The runner container should:

- download a pinned GitHub Actions Runner version
- persist runner configuration in a named volume
- connect outbound only
- use labels: `self-hosted`, `linux`, `private-lab`, `docker`

**Prefer JIT/ephemeral runner registration** (`--jitconfig`, one job then auto-deregister) over a long-lived persistent runner — GitHub's hardening guide names this as the primary mitigation for registration/persistence risk, and it also limits the blast radius of the documented `ps`-based secret leak (any secret passed as a CLI arg to a job is visible to other processes on the same runner host via `ps x -w`). If a persistent runner is chosen instead for simplicity, record it as an explicit, time-boxed risk acceptance in `docs/security.md`.

### Important Security Restriction

```text
ONLY private repository workflows may target this runner.
```

This must be actively enforced, not merely stated as intent:

- Confirm and record repository visibility as `Private` in `docs/milestone-reports/M2-runner.md`.
- Do not enable this runner on any repository accepting external forks or contributions.
- Configure branch protection so `runner-smoke.yml` and any workflow targeting `[self-hosted, private-lab]` can only be triggered by collaborators with write access.

**Not sufficient on its own:** per GitHub's "Security hardening for GitHub Actions" guidance, *any* collaborator who can open a pull request on this private repo can compromise the runner if a workflow is triggered by `pull_request` — not just via `pull_request_target`. Restrict collaborators to fully trusted individuals and gate every self-hosted-runner workflow behind `workflow_dispatch` only.

Do not use `pull_request_target` with this runner, and do not add a `pull_request` trigger sourced from fork branches to any workflow targeting `[self-hosted, private-lab]`.

**Do not mount `/var/run/docker.sock` directly into the runner container.** Direct socket access is equivalent to unauthenticated root on the host. Use one of, in order of preference:

1. **Rootless / isolated execution** — `sysbox-runc` or a rootless Docker daemon.
2. **Docker-in-Docker (DinD) sidecar** — the runner gets its own isolated Docker daemon. Caveat: the standard `docker:dind` image commonly still needs `--privileged` on the sidecar unless paired with `sysbox-runc` (option 1) — do not assume this is automatically lower-risk than option 3.
3. **Socket proxy** — `docker-socket-proxy` allow-listing only needed API calls, denying host-level operations.

If direct socket access is still chosen for a specific milestone, record it as an explicit, time-boxed risk acceptance in `docs/security.md`.

### GitHub Workflow

Create `.github/workflows/runner-smoke.yml`, manual trigger (`workflow_dispatch:`), targeting `[self-hosted, private-lab]`. The job should print hostname, print Docker version, run an ephemeral test container, and call a local health endpoint.

### Validation Milestone M2

`Actions → runner-smoke → Run workflow`. Expected result: PASS. The log must prove it executed on the private server.

### Manual E2E Test M2

Before the test: confirm the server has no intentionally opened inbound public port.

From another network or device:

1. Open GitHub.com.
2. Trigger `runner-smoke`.
3. Watch the workflow start.
4. Verify the job runs on the private server.
5. Verify the workflow calls a service available only inside the private environment.
6. Verify the result appears in GitHub.

Record in `docs/milestone-reports/M2-runner.md`, explicitly answering: *"Can GitHub execute a controlled operation on the private server without inbound access to the private server?"* Expected answer: YES.

---

## M10 — GitHub Agentic Workflows

### Objective

Add `gh-aw` (repository-centric reasoning) without replacing normal Actions.

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

`gh-aw`'s reasoning step should invoke the harness chosen in Phase 1 M9 (`opencode` or `pi`) where a local agent CLI is needed, rather than introducing a third tool. `gh-aw` (`github/gh-aw`) explicitly supports GitHub Copilot, Claude Code, OpenAI Codex, Gemini, and **Pi** as engines — confirm the `pi` engine option against current `gh-aw` docs at implementation time.

### First Agentic Workflow

`gh-aw` source files live in the **same directory as regular Actions workflows**, not a separate one — create `.github/workflows/investigate-failure.md`, then run `gh aw compile` to generate the executable `.github/workflows/investigate-failure.lock.yml` sibling. Commit both — Actions executes the compiled `.lock.yml`, not the Markdown source.

It should:

1. inspect a failed Actions run
2. inspect relevant repository files
3. describe probable root cause
4. create a bounded output

Do not initially let it: deploy, modify infrastructure, control Docker host arbitrarily, or manipulate hardware. Enforce this with `gh-aw`'s documented **"safe outputs"** mechanism (a separate, permission-scoped job for validated writes) rather than relying on the prose constraint alone.

**Also enforce network and permission boundaries, not just request them:** since this runs on a self-hosted runner, configure gh-aw's Agent Workflow Firewall (`network: { firewall: true, allowed: [...] }` in frontmatter) scoped to only the domains the investigation needs — unrestricted egress on a self-hosted runner could exfiltrate data or reach internal-only services, violating Rule 6. Also declare an explicit minimal `permissions: { contents: read }` block rather than relying on safe-outputs' default alone — this is a private repo, so gh-aw's public-repo integrity auto-filtering doesn't apply here.

### Keep Deterministic Capabilities Separate

Example normal workflow: `.github/workflows/local-capability.yml`, performing build/test/simulation. The agent can request the capability but should not reimplement it itself.

### Validation Milestone M10

Create a known build failure. Expected lifecycle: CI fails → agentic workflow executes → agent investigates → result is visible in GitHub.

### Manual E2E Test M10

1. Introduce the documented test failure.
2. Push branch.
3. Observe deterministic CI fail.
4. Trigger or observe `gh-aw`.
5. Review agent reasoning.
6. Verify the agent did not perform unauthorized actions.

Record in `docs/milestone-reports/M10-gh-aw.md`.

---

## Phase 2 Manual E2E Testing (performed by you, the agent)

You, as the agent, must personally execute every Manual E2E Test in this phase (M2, M10) end-to-end — from a network outside the server's LAN for M2, and against a real seeded CI failure for M10. Do not simulate the runner triggering or the `gh-aw` reasoning step; trigger them for real and observe the actual result in GitHub. Capture command output, exit codes, and timestamps per the evidence standard (`docs/INITIAL.md` Section 3, Rule 2), and record results in `docs/milestone-reports/M2-runner.md` and `M10-gh-aw.md` before considering Phase 2 complete.

---

## Phase 2 Documentation & Agent Instructions Update

Before Phase 2 is considered done, you, as the agent, must:

1. **Update project docs** — update `docs/architecture.md` and `docs/security.md` to describe the actual runner setup (rootless/DinD/socket-proxy mitigation chosen, actual labels, branch-protection config) and the `gh-aw` reasoning boundary that was implemented.
2. **Update `AGENTS.md`** at the repo root with:
   - **Guidelines** — any new binding rule discovered (e.g. runner registration quirks, `gh-aw` prompt constraints, GitHub API rate-limit behavior observed).
   - **Agent Instructions** — how to register/unregister the runner, how to trigger `runner-smoke.yml` and the `gh-aw` investigator manually, and how the chosen harness (`opencode`/`pi`) is invoked from within `gh-aw`.
   - **Lessons Learned** — a dated entry (`## Phase 2 — <date>`) covering what broke, what surprised you, and what to avoid next time. Append; do not overwrite Phase 1's entry.

---

## Phase 2 Exit Criteria

- [ ] Self-hosted runner registered, labeled `[self-hosted, private-lab]`, connects outbound only, either via JIT/ephemeral registration or with a documented time-boxed risk acceptance for a persistent runner.
- [ ] Runner base image pinned by digest, minimal final image, rebuild cadence documented.
- [ ] Docker socket is not directly mounted into the runner (mitigation from M2 applied).
- [ ] `runner-smoke.yml` passes, triggered from outside the server's LAN, with no inbound port opened.
- [ ] `gh-aw` investigates a seeded CI failure and produces a bounded, non-destructive diagnosis using the chosen harness (`opencode`/`pi`), with an explicit network firewall allowlist and minimal `permissions:` block configured.
- [ ] `docs/milestone-reports/M2-runner.md` and `M10-gh-aw.md` are committed with command-level evidence.
- [ ] `docs/architecture.md` and `docs/security.md` reflect the actual Phase 2 implementation.
- [ ] `AGENTS.md` has updated Guidelines, Agent Instructions, and a dated Phase 2 Lessons Learned entry.
