> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 2 — GitHub Automation Backbone

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
