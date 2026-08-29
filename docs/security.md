# Security — cade

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
{"nameWithOwner":"tbrandenburg/cade","visibility":"PUBLIC"}
```

`tbrandenburg/cade` is currently **PUBLIC**, not private. This is a
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
2. `docker run --rm cade/runner:latest --jitconfig <config>` starts
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
  `PLUGINS`, `NODES`, `SERVICES`, `TASKS`, `SECRETS`, `CONFIGS` —
  no host-level or lateral-movement operations.
- **M15 update:** `BUILD` was turned on deliberately (was `0` through M14)
  so `.github/workflows/embedded-build.yml` can run `docker build` for the
  deterministic embedded-sim firmware image. This is a minimal, scoped
  widening, not a general relaxation: `docker build`'s context is streamed
  to the daemon over the API from the client (the runner container), so it
  never needed - and still doesn't get - a bind-mounted host path; `EXEC`/
  `VOLUMES`/`NETWORKS`/`SWARM`/`SYSTEM` remain denied.
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

## M10 — GitHub Agentic Workflows (`gh-aw`)

### Reasoning boundary

`.github/workflows/investigate-failure.md` (compiled to
`investigate-failure.lock.yml` by `gh aw compile`) reasons about CI
failures without write access:

- `permissions: { contents: read, actions: read, copilot-requests: write }`
  — no `issues: write`, `pull-requests: write`, or `contents: write` at the
  agent-job level. The engine is `pi` (per Phase 1 M9's harness choice —
  `opencode` is not a supported gh-aw engine, so `pi`, which M9 also
  installed and validated, is used instead of introducing a third tool).
- `safe-outputs.create-issue` (`max: 1`) is the **only** permitted side
  effect. Issue creation runs in a separate, permission-scoped job that
  only executes after gh-aw's built-in threat-detection job passes — the
  agent job itself never holds `issues: write`.
- `network.allowed: [defaults, github, threat-detection]` — no wildcard
  domains; the agent cannot reach arbitrary hosts.
- The trigger is `on.workflow_run` (not `pull_request`/`issue_comment`),
  scoped to `workflows: ["local-capability"]` and `branches: [main]`, with
  gh-aw's automatic repository-ID/fork checks — this is safe on this
  PUBLIC repo per the same reasoning as M2 (`workflow_run` always uses the
  workflow file from the default branch, not a PR head branch, so it is
  not fork-exploitable the way `pull_request` is).

### Known limitation: self-hosted runner Docker-socket-proxy incompatibility (open, not yet resolved)

Live E2E validation (2026-08-28, run
[33191530756](https://github.com/tbrandenburg/devenv-cloud/actions/runs/33191530756))
confirmed the workflow_run trigger fires correctly and the M2 JIT runner
picks up the `agent` job, but the job then fails:

```
! '/var/run/docker.sock' does not exist on this runner.
X Cannot determine Docker socket group for '/var/run/docker.sock'. Set
  GH_AW_DOCKER_SOCK_PATH and GH_AW_DOCKER_SOCK_GID to configure the socket
  path and group explicitly.
```

`gh-aw`'s MCP Gateway/AWF sandbox requires a real Docker socket (a Unix
socket path, or `GH_AW_DOCKER_SOCK_PATH`/`GH_AW_DOCKER_SOCK_GID` pointing to
one) to spawn its sandbox/MCP containers. M2's runner deliberately has **no**
socket — only a `DOCKER_HOST=tcp://runner-docker-proxy:2375` proxy — and
`tcp://` targets are explicitly not supported for gh-aw's socket-mount
detection (confirmed in gh-aw's self-hosted-runners docs). Bind-mounting the
real socket into the runner (even read-only) reopens the unauthenticated-root
risk M2 deliberately mitigated with the socket proxy, so this was **not**
silently done as part of this step. Resolving it (e.g. a second, more
narrowly-scoped Docker daemon dedicated to gh-aw jobs, or an updated proxy
that exposes a real bind-mountable socket with an equivalent API allow-list)
is left as an explicit follow-up, not a silent workaround.

### Known limitation: no AI engine credentials configured (open, not yet resolved)

No `COPILOT_GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, or `OPENAI_API_KEY` secret is
configured on this repository (`gh secret list` returns empty), so even past
the Docker-socket blocker above, the `pi` engine has no model backend to call
in a live run. Adding one of these secrets is a repository-owner action (an
external credential), not something this step can create.


## M12 — Governance Foundation

**Timestamp (UTC):** 2026-08-28T19:46:20Z

### OpenBao — secrets store

- `compose.yaml`'s `openbao` service (`openbao/openbao:2.6.2`), config at
  `governance/openbao/config/openbao.hcl`, file storage backend (single
  node, no HA requirement for this local stack). Bound to
  `127.0.0.1:${OPENBAO_PORT:-8200}` only, same posture as `lab-sim`/`opa`.
- **TLS is mandatory on the listener** — `scripts/openbao-gen-cert.sh`
  generates a self-signed cert/key pair into `governance/openbao/certs/`
  (gitignored, regenerated per host, never committed) if one doesn't
  already exist. Plain HTTP is not offered.
- **Bootstrap procedure** (`scripts/openbao-init.sh`, idempotent):
  1. `bao operator init` (5 key shares, threshold 3) if not already
     initialized; unseal with 3 of the 5 shares.
  2. Enable the `kv-v2` secrets engine at `secret/`.
  3. Write a freshly generated (never previously used) random value for
     every Phase 1–3 credential into `secret/devenv-cloud/*` (see rotation
     log below) — the old `.env` values are discarded, not reused.
  4. Enable the `approle` auth method and a least-privilege
     `devenv-cloud-read` policy (`secret/data/devenv-cloud/*`, read-only)
     for non-root access going forward.
  5. **Revoke the initial root token.** Verified live: a `bao kv get`
     issued with the revoked root token returns `403 permission denied`.
- **Key file permissions:** `scripts/openbao-gen-cert.sh` originally
  `chmod 644`d both the cert and the private key; the private key has
  since been tightened to `640` (owner read/write, group read only, no
  world access) — `644` on a private key is world-readable and undermines
  the same TLS threat model the listener exists to close. `640` (not
  `600`) is required rather than owner-only because the container runs as
  a different uid but a matching gid, and needs group-read to load the key
  through the read-only bind mount. Applied to the on-disk key
  (`governance/openbao/certs/openbao.key`) and verified the `openbao`
  container still serves TLS correctly after a restart.
- **Unseal key shares:** written once, by the bootstrap script, to
  `governance/openbao/unseal/init.json` — this path is in `.gitignore` and
  MUST be moved to an out-of-band store (password manager / physical safe)
  and deleted from disk immediately after bootstrap. Milestone M14's
  `scripts/backup.sh` now backs up the OpenBao storage directory itself
  (the mechanism-appropriate equivalent for the `file` storage backend —
  see `docs/disaster-recovery.md`); the unseal key shares themselves still
  need to live out-of-band, separately from any backup artifact, since
  they are the only thing that can decrypt that backup.
- **Credential rotation log** (Phase 1–3 credentials, rotated under the
  interim secret-handling rule, `docs/INITIAL.md` Section 3 Rule 3 — new
  values live only in OpenBao's `secret/devenv-cloud/*`, never printed or
  written to a file by the bootstrap script):
  | Credential | Introduced | Rotated to |
  |---|---|---|
  | `CODER_PG_PASSWORD` (coder-db) | M1 | `secret/devenv-cloud/coder-db` |
  | `TEMPORAL_PG_PASSWORD` (temporal-db) | M8 | `secret/devenv-cloud/temporal-db` |
  | `LAB_SIM_TOKENS` (agent-a, agent-b) | M11 | `secret/devenv-cloud/lab-sim` |

  Applying the rotated values to the live services (updating `.env` and
  restarting the affected containers) is an operator action performed
  after reading the new values out of OpenBao — intentionally not
  automated by the bootstrap script, so a credential is never written back
  to a plaintext `.env` file by tooling.

### OPA — policy decisions for the M11 lab-sim MCP server

- `compose.yaml`'s `opa` service (`openpolicyagent/opa:1.9.0`), serving
  `governance/opa/policy/lab_authz.rego` (package `lab.authz`) via its
  decision API. Bound to `127.0.0.1:${OPA_PORT:-8181}` plus reachable from
  `platform-workspaces` as `http://opa:8181`. No `healthcheck` is defined —
  the upstream image is distroless (no shell/wget/curl to run one with,
  confirmed via `docker exec`); `lab-sim` depends on `service_started`
  only, which is sufficient since OPA serves in well under a second.
- Policy behavior (pinned by `governance/opa/policy/lab_authz_test.rego`,
  `opa test` — 6/6 passing):
  - `allow read_device`
  - `allow run_test`
  - `flash_device` allowed only when `input.approved == true`
- `mcp/lab-sim/src/lab_sim/policy.py` queries
  `POST /v1/data/lab/authz/allow` live before `run_test`/`flash_device`
  execute (`server.py`) — the allow/deny logic is never hardcoded in the
  MCP server; a transport failure fails closed (denied), not open.
- **Live validation** (`scripts/verify-governance.sh`, not just `opa test`):
  a real MCP tool-call round trip through the running `lab-sim` container
  confirmed `run_test` → ALLOW and `flash_device` (no `approved` argument)
  → DENY, then `flash_device` with `approved=true` → ALLOW, exactly per the
  Milestone M12 validation requirement.

### Keycloak — optional, disabled by default

`compose.yaml`'s `keycloak` service is gated behind
`docker compose --profile governance up` — absent from the default
`make up` (`docker compose up -d`) stack. Uses `start` (not `start-dev`,
which Keycloak's own docs call out as unsafe for anything beyond a quick
demo) and requires `KEYCLOAK_ADMIN_PASSWORD` to be set in `.env` before it
will boot (no hardcoded default password).

## M13 — Observability

Grafana is the only observability service published to the host
(`127.0.0.1`-bound); Prometheus and Loki are internal-only, reached
through Grafana's provisioned datasources. No telemetry data leaves the
host. See `docs/operations.md` for the dashboard/correlation runbook.

## M14 — Backup / Restore

Backup artifacts (`backup/artifacts/`, gitignored) contain a full
plaintext copy of every MUST BACK UP secret store (OpenBao's raw storage
directory, both Postgres databases, the Coder/session home volumes) —
treat a backup set with the same sensitivity as the live secrets store
itself: encrypt at rest and restrict access if retained beyond a
disposable test cycle. See `docs/disaster-recovery.md` for the full
backup/restore procedure and the OpenBao `file`-backend deviation from
the plan's literal Raft-snapshot wording.

## M15/M16 — Final integration

No new attack surface was introduced integrating the pieces above — the
Final E2E scenario (`docs/plan/plan.md` M15/M16 section) reuses the same
JIT self-hosted runner (M2), the same OPA-gated `lab-sim` MCP tool calls
(M12), and the same `workflow_dispatch`-only, network-firewalled `gh-aw`
investigator (M10) already documented. The two open `gh-aw` limitations
above (docker-socket-proxy incompatibility, no AI engine credentials)
remain open and unresolved at `0.1.0` — not silently worked around.

## Issue #5 MVP — build-docker-proxy

`temporal-worker`'s new `run_build_command` Activity reaches Docker
through its own `build-docker-proxy` service (`tecnativa/docker-socket-
proxy`), deliberately separate from `runner-docker-proxy` (M2) — a
different consumer with a different allow-list rather than widening an
existing proxy's scope. Only `CONTAINERS`, `IMAGES`, `POST`, `VERSION`,
and `PING` are enabled; `EXEC`, `VOLUMES`, `NETWORKS`, `SWARM`, `SYSTEM`,
and `BUILD` all stay denied (unlike `runner-docker-proxy`, this Activity
never needs `docker build`, only `docker run` against a pre-built image).
Not published to the host — reachable only from `platform-workspaces`.
The OPA policy gate the issue's larger plan calls for (approve/deny which
images/commands may run) is explicitly out of scope for this MVP slice
and remains a follow-up.

