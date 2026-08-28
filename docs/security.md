# Security — devenv-cloud

Actual security posture as implemented, per milestone. Keep in sync with
`docs/ARCHITECTURE.md` and the risk-acceptance requirements in
`docs/plan/plan.md`.

## M2 — Self-Hosted GitHub Runner

### Repository visibility — OPEN RISK, NOT YET RESOLVED

The plan requires (`docs/plan/plan.md`, M2): *"Confirm and record repository
visibility as `Private`"* and *"ONLY private repository workflows may target
this runner."*

```
$ gh repo view --json visibility,nameWithOwner
{"nameWithOwner":"tbrandenburg/devenv-cloud","visibility":"PUBLIC"}
```

`tbrandenburg/devenv-cloud` is currently **PUBLIC**, not private. This is a
genuine, unresolved conflict with the plan's core M2 security precondition,
not an oversight to silently work around:

- On a public repo, *any* GitHub user can open a pull request. Per GitHub's
  "Security hardening for GitHub Actions" guidance, a workflow triggered by
  `pull_request` (not just `pull_request_target`) from an untrusted fork can
  compromise a self-hosted runner.
- This repository's history shows the same fact was already surfaced twice
  before (M3, M4 milestone reports) and is called out as a recurring
  false-blocker/true-risk in `AGENTS.md` → Lessons Learned. It has not been
  changed to private since.

**Mitigations applied so the runner can still exist safely today, given the
public visibility:**

- `runner-smoke.yml` (and every workflow targeting
  `[self-hosted, private-lab]`) uses `workflow_dispatch` **only** — no
  `pull_request`, `pull_request_target`, `issue_comment`, or any other
  trigger that can be sourced from an untrusted actor or fork branch.
- `permissions: { contents: read }` is declared explicitly at the workflow
  level (least privilege, not relying on repository defaults).
- The runner is JIT/ephemeral (see below) — it does not exist between runs,
  so there is no standing target even if a workflow trigger mistake were
  made later.
- Repository collaborators are limited to trusted accounts (owner only, at
  time of writing).

**This is a risk acceptance, not a resolution.** Making the repository
private is an intentional decision affecting the project's public/portfolio
visibility and is left to the repository owner — it is not something this
step (`00100-self-hosted-github-runner.md`) makes unilaterally. Until the
repo is made private, self-hosted-runner workflows MUST remain restricted to
`workflow_dispatch` with no fork-reachable triggers, per the mitigations
above.

### Runner registration model: JIT/ephemeral

Chosen over a persistent runner, per the plan's stated preference. Flow
(`scripts/runner-jit-start.sh`):

1. `gh api repos/<owner>/<repo>/actions/runners/generate-jitconfig` requests
   a one-time, single-job JIT configuration (labels:
   `self-hosted, linux, private-lab, docker`).
2. `docker run --rm devenv-cloud/runner:latest --jitconfig <config>` starts
   the runner container, which executes exactly one job and exits — no
   registration token or long-lived runner identity is ever persisted on
   disk or in the image.
3. GitHub auto-deregisters the runner once the job finishes (JIT contract).

This also limits the blast radius of the documented `ps`-based secret leak
(any secret passed as a CLI arg to a job is visible to other processes on
the same host via `ps x -w`): there is no persistent runner process for a
leaked secret to be scraped from after the job ends.

### Docker access: socket proxy, not a mounted socket

`/var/run/docker.sock` is **not** mounted into the runner container.
Mounting it directly is equivalent to unauthenticated root on the host.
Chosen mitigation (option 3 in the plan's preference order — socket proxy):

- `runner-docker-proxy` (`tecnativa/docker-socket-proxy:v0.5.0`, see
  `compose.yaml`) is the only container with the real Docker socket bind
  mounted (read-only). It is not published to the host and is reachable
  only from the `platform-workspaces` Docker network.
- Allow-listed API groups: `CONTAINERS`, `IMAGES`, `POST`, `VERSION`,
  `PING` — enough to run `docker version` and `docker run --rm
  hello-world`.
- Explicitly denied: `EXEC`, `VOLUMES`, `NETWORKS`, `SWARM`, `SYSTEM`,
  `BUILD`, `PLUGINS`, `NODES`, `SERVICES`, `TASKS`, `SECRETS`, `CONFIGS` —
  no host-level or lateral-movement operations.
- The runner container reaches it via `DOCKER_HOST=tcp://runner-docker-proxy:2375`,
  set per-step in `runner-smoke.yml` (not baked into the image or a global
  env, so a compromised job can't silently rely on it existing elsewhere).

Rootless Docker / `sysbox-runc` (option 1) was not chosen for M2: it adds a
host-level dependency (an alternate container runtime) beyond what the
smoke workflow's scope (print versions, run one ephemeral container, call a
local HTTP endpoint) justifies. Revisit if a future milestone needs
build-in-container (`docker build`) capability, which the current
allow-list intentionally excludes.

### Branch protection / trigger restriction

- `runner-smoke.yml` and any future `[self-hosted, private-lab]` workflow
  must use `workflow_dispatch` only (enforced by convention + code review
  today; GitHub branch-protection rules do not have a native "restrict who
  can workflow_dispatch" control beyond repository write-access, which
  already gates `workflow_dispatch` to collaborators with write access by
  default).
- No workflow targeting this runner may use `pull_request_target`, or
  `pull_request` sourced from fork branches.

### Base image pinning

`runner/Dockerfile` pins `ubuntu:24.04` by digest
(`sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517`),
not just the mutable `24.04` tag — the highest-security-sensitivity image
in the plan. The GitHub Actions Runner release tarball
(`actions-runner-linux-x64-2.337.0.tar.gz`) is pinned by version and
verified against a hardcoded SHA-256 checksum at build time
(`sha256sum -c -`) before being unpacked. See `docs/operations.md` for the
rebuild/patch cadence.
