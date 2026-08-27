# Phase 2 — GitHub Automation Backbone

## Phase Objective

Prove that GitHub can trigger deterministic CI and repository-centric agent reasoning on the private server, using an outbound-only connection — independent of Phase 1's interactive workspace.

Milestones covered: **M2** (Self-Hosted GitHub Runner), **M7** (GitHub Agentic Workflows).

Depends on Phase 1 only for the repository/agent harness existing (`opencode`/`pi` chosen as default in M6); does not depend on Coder workspaces being up.

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

Build the runner image in `runner/Dockerfile`. Do not depend on an opaque third-party runner image. The runner container should:

- download a pinned GitHub Actions Runner version
- persist runner configuration in a named volume
- connect outbound only
- use labels: `self-hosted`, `linux`, `private-lab`, `docker`

### Important Security Restriction

```text
ONLY private repository workflows may target this runner.
```

This must be actively enforced, not merely stated as intent:

- Confirm and record repository visibility as `Private` in `docs/milestone-reports/M2-runner.md`.
- Do not enable this runner on any repository accepting external forks or contributions.
- Configure branch protection so `runner-smoke.yml` and any workflow targeting `[self-hosted, private-lab]` can only be triggered by collaborators with write access.

Do not use `pull_request_target` with this runner, and do not add a `pull_request` trigger sourced from fork branches to any workflow targeting `[self-hosted, private-lab]`.

**Do not mount `/var/run/docker.sock` directly into the runner container.** Direct socket access is equivalent to unauthenticated root on the host. Use one of, in order of preference:

1. **Rootless / isolated execution** — `sysbox-runc` or a rootless Docker daemon.
2. **Docker-in-Docker (DinD) sidecar** — the runner gets its own isolated Docker daemon.
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

## M7 — GitHub Agentic Workflows

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

`gh-aw`'s reasoning step should invoke the same harness chosen in Phase 1 M6 (`opencode` or `pi`) where a local agent CLI is needed, rather than introducing a third tool.

### First Agentic Workflow

Create `.github/agentic-workflows/investigate-failure.md`. It should:

1. inspect a failed Actions run
2. inspect relevant repository files
3. describe probable root cause
4. create a bounded output

Do not initially let it: deploy, modify infrastructure, control Docker host arbitrarily, or manipulate hardware.

### Keep Deterministic Capabilities Separate

Example normal workflow: `.github/workflows/local-capability.yml`, performing build/test/simulation. The agent can request the capability but should not reimplement it itself.

### Validation Milestone M7

Create a known build failure. Expected lifecycle: CI fails → agentic workflow executes → agent investigates → result is visible in GitHub.

### Manual E2E Test M7

1. Introduce the documented test failure.
2. Push branch.
3. Observe deterministic CI fail.
4. Trigger or observe `gh-aw`.
5. Review agent reasoning.
6. Verify the agent did not perform unauthorized actions.

Record in `docs/milestone-reports/M7-gh-aw.md`.

---

## Phase 2 Exit Criteria

- [ ] Self-hosted runner registered, labeled `[self-hosted, private-lab]`, connects outbound only.
- [ ] Docker socket is not directly mounted into the runner (mitigation from M2 applied).
- [ ] `runner-smoke.yml` passes, triggered from outside the server's LAN, with no inbound port opened.
- [ ] `gh-aw` investigates a seeded CI failure and produces a bounded, non-destructive diagnosis using the chosen harness (`opencode`/`pi`).
- [ ] `docs/milestone-reports/M2-runner.md` and `M7-gh-aw.md` are committed with command-level evidence.
