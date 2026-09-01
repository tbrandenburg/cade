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

## Issue #6 — devcontainer template: per-workspace privileged Docker-in-Docker

`coder/templates/devcontainer/main.tf`'s workspace container runs
`privileged = true` with its own nested, per-workspace `dockerd` (backed by
a dedicated `docker_volume` at `/var/lib/docker`), replacing an earlier
docker-outside-of-docker design (host `/var/run/docker.sock` bind-mount)
that a live E2E found not just risky but functionally broken — see
`docs/devcontainer-security-notes.md` for the full incident writeup and
design rationale. `privileged = true` is still a real, accepted tradeoff
(root-equivalent on the host kernel), but it's scoped per-workspace rather
than sharing one host-wide Docker socket across every workspace. This
matches Coder's own official reference template's documented default for
Docker-only deployments without a Sysbox-capable host; live-verified
working end-to-end (real clone, real nested daemon, real inner-container
build, Durability Test 3 passing) on 2026-08-29.


## Issue #5 MVP — build-docker-proxy

`temporal-worker`'s new `run_build_command` Activity reaches Docker
through its own `build-docker-proxy` service (`tecnativa/docker-socket-
proxy`), deliberately separate from `runner-docker-proxy` (M2) — a
different consumer with a different allow-list rather than widening an
existing proxy's scope. Only `CONTAINERS`, `IMAGES`, `POST`, `VERSION`,
`PING`, and (since Issue #49) `EXEC` are enabled; `VOLUMES`, `NETWORKS`,
`SWARM`, `SYSTEM`, and `BUILD` all stay denied (this Activity never needs
`docker build`, only `docker run`/`docker exec` against a pre-built
image or an already-running container). Not published to the host —
reachable only from `platform-workspaces`.
The OPA policy gate the issue's larger plan calls for (approve/deny which
images/commands may run) is explicitly out of scope for this MVP slice
and remains a follow-up.

### Issue #49 — persistent-container exec (`EXEC` widened)

`run_build_command` gained an optional `container_name` parameter: when
set, the command runs via `docker exec` against an already-existing,
already-running container (typically a real Coder workspace, named
`coder-<owner>-<workspace>`) instead of an ephemeral one — Temporal never
creates/stops/starts/deletes that container, only executes inside it.
This required widening `build-docker-proxy`'s `EXEC` flag from `0` to `1`
(proven necessary live: with `EXEC=0`, `container.exec_run(...)` against
this proxy returned `403 Forbidden by administrative rules`, the same
class of docker-socket-proxy denial already documented in AGENTS.md for
`runner-docker-proxy`'s `BUILD=1` fix). No other flag was widened; the
default (no `container_name`) ephemeral path is completely unaffected.


Gap-fill: `run_build_command` is now gated by OPA's `build.authz` policy
(`governance/opa/policy/build_authz.rego`), evaluated live via OPA's
decision API (`POST /v1/data/build/authz/allow`) before any container is
run — mirroring the M12 `lab.authz` pattern. Default is fail-closed: only
images on an explicit allow-list (`cade/coder-workspace:latest`,
`cade/embedded-linux-workspace:latest`) are permitted; any other image, a
missing/unreachable OPA decision API, or a non-`true` result all deny the
request.

### Issue #8 — template-aware image selection

`BuildWorkflow.run`/`demo.build_starter` now accept an optional
`--template` (`docker-workspace` / `embedded-linux`) that resolves via a
small lookup table (`demo.build_workflow.TEMPLATE_IMAGES`) to the correct
pre-built image tag, kept in sync with `build_authz.rego`'s
`allowed_images` allow-list. Precedence: an explicit `--image` always
wins (unchanged pre-#8 behavior); else `--template` is resolved; else the
original hardcoded default (`cade/coder-workspace:latest`) is used.
Live-verified 2026-08-29 (see the "orphan container" evidence below for
the same session): both templates, an explicit `--image`, and the
no-argument default all resolved to the correct image and ran
successfully; the deny case (`--image alpine:latest`) was re-run and
still correctly denied by OPA with zero container created — no
regression from #5.

### Issue #8 — orphaned container on mid-Activity worker crash

Confirmed root cause, live: docker-py's `containers.run(..., remove=True)`
(the code path used here, `detach=False`) removes the container
client-side, calling `container.wait()` then `container.remove()` — it
does **not** set the daemon-side `AutoRemove` flag (only the `detach=True`
path does, per docker-py's own source). Reproduced by starting a
long-running Activity (`sleep 30` inside `cade/coder-workspace:latest`),
`docker kill`-ing the `temporal-worker` container mid-run, and confirming
the started container kept running/exited untouched on the Docker daemon
with nothing left to clean it up.

Fix: every container `run_build_command` starts is labeled
(`cade.build-activity.task-key`) with a key stable across Temporal retry
attempts of the same Activity task (workflow ID + Activity ID, not the
attempt number). Before starting a container, the Activity looks up and
force-removes any container already carrying its own task key — cleaning
up exactly the leftover from a previous, crashed attempt of the *same*
Activity task, and only that container (never another task's). The
default `RetryPolicy(maximum_attempts=1)` was also raised to `2`:
`run_build_command` catches every Docker/OPA-level error itself and
returns it as a structured `{"ok": False, ...}` result rather than
raising, so this change only ever affects genuine infra faults (an
unhandled exception, or the Activity timing out because the worker
process that was running it crashed) — it can never cause a retry of a
legitimate build/test command failure.

Live-verified end-to-end 2026-08-29: started `BuildWorkflow` with
`--command sleep 30`, killed `temporal-worker` ~5s in, confirmed the
orphaned container (`angry_lovelace`) was still present (`Up`, later
`Exited (0)`, never removed) after restarting `temporal-worker`, then
waited out the Activity's 5-minute `start_to_close_timeout` for Temporal
to time out attempt 1 and dispatch attempt 2. Attempt 2's worker log
recorded `reaping orphaned container ... from a previous attempt of
task_key=crash-test-1-1`, the workflow completed successfully
(`{"ok": true, "exit_code": 0, ...}`), and `docker ps -a` afterward showed
zero leftover `cade/coder-workspace:latest` containers. `build-docker-proxy`
being briefly unreachable was not separately exercised live in this
session (out of scope for the crash reproduction above) — the existing
fail-closed pattern (`docker client init failed` / `docker API error`
returned as a structured error dict, mirroring the already-verified
OPA-unreachable fail-closed behavior) is unchanged by this fix and was
not modified.

### OPA policy reload

`compose.yaml`'s `opa` service bind-mounts `governance/opa/policy` into
the container read-only, and OPA's `run --server` mode does not
hot-reload that mount — a new or changed `.rego` file only takes effect
after the `opa` process restarts. `scripts/reload-opa-policy.sh`
automates this (restart `opa`, wait for it to become responsive, then
smoke-query both `lab.authz.allow` and `build.authz.allow` to confirm the
restarted server actually has the current policy files loaded) and is
run automatically as the first step of `scripts/verify-governance.sh` /
`make governance-verify`, so any policy edit is guaranteed to be live
before verification runs on this single host.

That live-reload step is not itself automated by anything other than a
human remembering to run `make governance-verify` — a policy edit merged
to `main` does not, by itself, restart the live `opa` container (Issue
#9). For a single-operator, single-host platform, standing up new
always-running infrastructure to watch `governance/opa/policy/` for
changes (a file-watcher sidecar, a `compose.yaml` healthcheck hook, etc.)
is unjustified extra complexity for how infrequently policy changes,
and every such change already goes through PR review. Instead, the
enforced discipline is a two-part split:

- **CI gate (automated, before merge)** —
  `.github/workflows/opa-policy-check.yml` triggers on any push/PR
  touching `governance/opa/policy/**` and runs
  `scripts/opa-policy-check.sh` (also `make opa-policy-check`): `opa
  test` against the changed policy bundle, plus an ALLOW/DENY decision
  smoke check for both `lab.authz` and `build.authz` against a
  throwaway, job-scoped `opa` server on the GitHub-hosted runner — no
  live platform stack required. This is the provable-correctness half:
  a policy typo/regression is caught before merge, not discovered live.
- **Operational discipline (documented, after deploy)** — after a
  policy change merges to `main`, the operator runs `make
  governance-verify` (or, for just the reload step, `bash
  scripts/reload-opa-policy.sh`) against the live single-host stack to
  restart the running `opa` container and confirm it picked up the
  merged policy. This is intentionally still a manual step, not new
  standing infrastructure — tracked here rather than left as tribal
  knowledge.

## Issue #50 — Temporal-owned persistent Coder workspaces: `temporal-svc` token scope

`temporal-worker` can now resolve-or-create a Coder workspace on demand
(`demo/coder_client.py`, `demo/workspace_activity.py`) and reap idle ones
on a schedule, entirely through the Coder API. It authenticates as a
dedicated Coder user, `temporal-svc` (not any human/admin account),
using a token minted by `scripts/coder-svc-token.sh` (`make
coder-svc-token`) and delivered via `CODER_WORKSPACE_API_TOKEN` —
deliberately a *different* env var from `CODER_SESSION_TOKEN` (that one
is the more-privileged, host-side admin token `make ai-bootstrap` uses
for a completely unrelated purpose; reusing the name would risk either
var accidentally inheriting the other's value/privilege).

**Exact scopes minted** (verified live against Coder v2.36.3, using the
current `scopes: [...]` array field — never the deprecated all-or-nothing
singular `scope: "all"`):

```
coder:workspaces.create
coder:workspaces.operate
organization:read
template:read
```

(`coder:workspaces.delete` is added only if
`CODER_WORKSPACE_REAP_ACTION=delete`; default is `stop`.)

This set is composite-first (the two `coder:workspaces.*` scopes cover
create/start/stop for workspaces this user owns) plus two narrow,
read-only, low-level scopes. **This token cannot read other users, list
or modify templates (`template:read` is read-only), read audit logs, or
act on any workspace it does not itself own** — verified live via 404/403
responses for out-of-scope calls during implementation.

**Correction vs. this issue's own comment 2** (found only by live
testing against the real server, not documented anywhere beforehand):
`coder:workspaces.create`/`.operate` alone are *not* sufficient to create
a workspace — `GET /api/v2/organizations` silently returns `200 []` (not
a 403/404) for a token scoped to only those two, and
`GET .../templates/{name}` 404s, both without any indication the
response was scope-truncated rather than genuinely empty/missing. This
silently produced a `"no organizations returned"` error on the *first*
live end-to-end attempt in this issue — resolving an organization id and
a template's `active_version_id` requires the additional `organization:read`
and `template:read` scopes, added above. **Any future addition to this
token's capability set must be verified the same way** (mint the token,
call the specific endpoint, check for a silent-empty-success rather than
trusting scope names alone) — a `200`/`201` response is not proof a
scope-restricted caller received real data.

A second correction, also found only live: `list_workspaces` (used by
the reaper) does not use `GET /api/v2/users/{owner}/workspaces` (this
issue's own draft plan) — that endpoint returns `405 Method Not Allowed`
on v2.36.3. The real scoped-listing endpoint is
`GET /api/v2/workspaces?q=owner:<owner>` (the same query-filter syntax
the Coder Web UI's workspace search box uses).

**§10 follow-up (2026-08-31): "Temporal Workflows" dashboard tile.**
`coder/templates/docker-workspace/main.tf` adds a conditional
`coder_app.temporal` tile, gated by the `temporal_owned` `coder_parameter`
(default `false`; `demo/workspace_activity.py` now passes `"true"` for
every `tw-`-prefixed workspace it creates). It is a pure UI convenience
link (`external = true`) deep-linking to Temporal UI's own workflow list,
filtered to the owning workspace's name — it grants no new backend
capability and does not widen `temporal-svc`'s token scope (above) or any
other token's. Verified live in a real browser: the tile and its icon
render with zero CSP violations once `coder`'s `CODER_ADDITIONAL_CSP_POLICY`
(`compose.yaml`) includes `http://localhost:${TEMPORAL_UI_PORT:-8088}`
under `img-src`, the tile's link correctly opens Temporal UI filtered to
the workspace, and the tile is absent entirely on a workspace created with
`temporal_owned=false` (the default).

## Issue #54 — OPA gate on Temporal-owned workspace lifecycle (`workspace.authz`)

Issue #50 shipped `demo/workspace_activity.py`'s `ensure_coder_workspace`
(create/start) and `reap_coder_workspaces` (stop/delete) with no
authorization gate of their own — only Coder's own RBAC (via the scoped
`temporal-svc` token above) as a backstop. This closes that gap with a
new policy, `governance/opa/policy/workspace_authz.rego` (package
`workspace.authz`, decision path `POST /v1/data/workspace/authz/allow`),
mirroring `build.authz`'s pattern/fail-closed philosophy exactly.

**Exact rule set** (pinned by `governance/opa/policy/workspace_authz_test.rego`):

- `create`/`start`: allowed only if `input.owner == "temporal-svc"` **and**
  `input.workspace_name` matches `^tw-[a-z0-9-]{1,29}$` — byte-for-byte
  the same pattern `workspace_activity.py`'s own `NAME_PATTERN` already
  validates in Python (the Rego rule does not invent a new constraint).
- `stop`: allowed unconditionally for `input.owner == "temporal-svc"`.
- `delete`: allowed only if `input.reap_action == "delete"` — the actual
  configured value of `CODER_WORKSPACE_REAP_ACTION` is passed through as
  part of the decision input, so the policy (not the Activity) decides
  whether a real delete is permitted; `reap_action` set to anything else
  (including the default `"stop"`, or missing entirely) denies delete.
- Default is `allow := false` for any other action, wrong owner, malformed
  name, or missing/empty input — same fail-closed default as `build.authz`.

**Wiring** (`temporal/src/demo/workspace_activity.py`): a `_opa_allows`
helper mirrors `build_activity.py`'s existing one (same `OPA_URL` config
source, same `httpx.post` pattern, same fail-closed-on-exception/
non-200/non-`true`-result behavior — deliberately duplicated rather than
extracted into shared code, consistent with this repo's existing
one-`_opa_allows`-per-activity-file style).

- `ensure_coder_workspace` calls it once, up front, with `action="create"`
  before any Coder API call — at that point in the flow it is not yet
  known whether the Activity will end up creating or starting the
  workspace (that depends on Coder's resolved state), but
  `workspace_authz.rego`'s allow conditions for `create` and `start` are
  identical, so a single upfront check with `action="create"` covers both
  outcomes. A deny (or an unreachable/erroring OPA) returns the same
  fail-closed `{"ok": false, "error": "denied by workspace.authz policy
  for name=... owner=..."}` shape `ensure_coder_workspace` already used
  for other error paths — never a silent pass-through.
- `reap_coder_workspaces`'s per-item loop calls it immediately before
  issuing the real stop/delete API call, passing the actual configured
  `CODER_WORKSPACE_REAP_ACTION` as `reap_action` and using it (mapped to
  `"stop"` or `"delete"`) as the gated action. A denial is recorded in the
  existing `skipped` list (`reason: "denied by workspace.authz for
  action=..."`) — consistent with how every other per-item failure in
  this loop is already handled (fail-closed per item, never abandoning
  the rest of the reaper run).

**Verification**: `opa test governance/opa/policy/` (23/23, including 12
new `workspace.authz_test` cases, no regressions to `build_authz_test`/
`lab_authz_test`) passes. `scripts/verify-governance.sh` was extended
with the same live-decision-API round trip pattern already used for
`lab.authz`: ALLOW for a valid `temporal-svc` create/start/stop and a
delete with `reap_action=delete`; DENY for a wrong-owner create, a
malformed-name create, and a delete with `reap_action=stop`. Because the
live `opa` container (shared across the whole repo, restarted by
`scripts/reload-opa-policy.sh`) bind-mounts `governance/opa/policy` from
the coordinator's own working tree rather than this issue's isolated
worktree, the live decision-API portion of `verify-governance.sh` could
only be confirmed to return the expected shape (not yet the new
policy's content) until this branch is merged and the coordinator
re-runs `scripts/reload-opa-policy.sh` against the merged tree — the
containerized `opa test` run against this worktree's own policy files
(23/23 passing) is what actually proves the new policy's logic.

## Issue #60 — JupyterLab/Node-RED workspace apps: auth model and confinement

Both apps run as plain, unprivileged processes inside the
`docker-workspace` (`docker-workspace`) template's already-confined
container (Issue #23's `security_opts` — untouched by this issue), bound
explicitly to `127.0.0.1` inside that container. Neither has its own
login/password/token:

- JupyterLab: `--IdentityProvider.token='' --ServerApp.password=''`.
- Node-RED: no `adminAuth` in `coder/workspace-apps/node-red-settings.js`.

This is deliberate, not an oversight: the *only* network path to either
listener is Coder's own agent-proxy, which already requires a valid
Coder session (the same mechanism gating every other `coder_app` in this
template, e.g. code-server). Nothing is published to the host, to
`compose.yaml`'s platform networks, or to any other workspace's
container — each is a private, per-workspace, per-user process on a
private loopback interface. A second login on top would be redundant
security theater, not a real additional boundary, and would break the
proxied deep-link (Coder's proxy does not forward interactive
login-prompt flows).

Both `coder_app` tiles reference same-origin, Coder-bundled icons
(`/icon/jupyter.svg`, `/icon/node.svg`) — **no**
`CODER_ADDITIONAL_CSP_POLICY` change was needed (verified live:
`docker inspect coder --format '{{.Config.Env}}'` showed
`CODER_ADDITIONAL_CSP_POLICY` byte-identical before/after this issue),
unlike Issue #47/#50's plain-http external-origin icon tiles.

The reference architecture this issue was scoped from
(`tbrandenburg/jupyter-nodered-sandbox`) runs `srt`/bubblewrap with
`cap_add: [SYS_ADMIN, NET_ADMIN]` + `seccomp=unconfined` +
`apparmor=unconfined` for its own separate purposes — **none of that was
adopted here**. `coder/templates/docker-workspace/security/*` (Issue
#23/#40's narrowly-scoped seccomp/AppArmor profiles) was not touched by
this issue at all; JupyterLab and Node-RED run under the exact same
confinement every other in-workspace process already does.

**Live-verified limitation, not a security issue**: Coder's own real
path-based `coder_app` proxy (v2.36.3) strips the app's URL prefix before
forwarding to the app, rather than preserving the full path. This breaks
JupyterLab's own domain-absolute static-asset loading in a real browser
(see `docs/operations.md`'s "Known limitation" for the full write-up) —
purely a usability gap, not an auth/confinement gap: the underlying
process is exactly as reachable (only via the authenticated proxy) either
way.


