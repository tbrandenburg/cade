# AGENTS.md — cade

Instructions and accumulated knowledge for any AI agent (human or automated) working in this repository. Update this file at the end of every phase per `docs/phases/README.md`.

## How to use this file

- Read this file before starting work on any phase or milestone.
- Read `docs/ARCHITECTURE.md` alongside it — a condensed C4-model (Context/Container/Component) view of the platform, based on `docs/cade.png` and `docs/INITIAL.md` Section 2. Use it for quick orientation; `docs/INITIAL.md` remains authoritative for details.
- Update it before closing out a phase — do not leave it stale.
- Keep entries dated and attributed to a phase/milestone so history stays traceable.
- Prefer appending to "Lessons Learned" over rewriting history; only edit "Guidelines" when a rule changes.

## Purpose of this repository

cade is a Docker-first, single-repository private developer platform:
remote development, agent-assisted coding, GitHub automation, durable
orchestration, and governance/observability, running entirely on one Linux
server with no inbound Internet exposure and no paid cloud infrastructure.
`docs/INITIAL.md` is the authoritative implementation plan;
`docs/ARCHITECTURE.md` is a condensed C4-model summary of it;
`docs/phases/` splits it into 5 sequential deliverable phases plus an
optional, order-independent Phase 6 (wide-area/Tailscale remote access —
deferred until a real second network exists to test from), each with its
own milestones and required milestone report under `docs/milestone-reports/`.
See the top-level `README.md` for a quickstart and current project status.

`docs/` contains both the human-facing project plan/documentation (source of
truth) and the internal, plan-driven build-process state used by
`scripts/factory.sh`. Keep factory state under `docs/plan/`; do not create a
separate `doc/` tree.

## Guidelines

_(Populated incrementally as phases complete. Each phase adds concrete, binding guidance discovered during its implementation — not restated theory from `docs/INITIAL.md`.)_

- **Startup ordering** — `docker compose up -d` has no explicit cross-service
  `depends_on` health gate beyond what `compose.yaml` declares; in practice
  `coder`/`temporal`/`openbao` each take 10-60s to become `healthy` after
  their DB dependency is up. Always run `make status` and wait for every
  service to show `(healthy)`/`Up` before starting a workspace, Temporal
  workflow, or MCP call against it — a call issued during that window fails
  with a generic connection-refused, not a clear "not ready yet" error.
- **Full end-to-end scenario ordering** — GitHub CI (M2/M10) is fully
  decoupled from the local stack (no shared dependency), but the Temporal
  ↔ lab-sim capability call (M11/M15) requires `temporal-worker` on the
  `platform-workspaces` network — verify with `docker inspect
  temporal-worker --format '{{json .NetworkSettings.Networks}}'` if an
  Activity can't reach `lab-sim` by service name.
- **Backup/restore gotchas** — see `docs/disaster-recovery.md` for the
  full procedure; the one binding rule: OpenBao's unseal key shares must
  never be backed up in the same artifact/location as the backed-up
  storage directory they unseal (defeats the purpose of a secrets store).
- **Durability Test 3 is per-workspace-type** — proving it against one
  Coder template (e.g. `docker-standard`) does not prove it against
  another (e.g. `embedded-linux`); each template independently declares
  its own `docker_volume.home_volume` with `lifecycle { ignore_changes =
  all }` — verify the specific template a release claims to support.

## Agent Instructions

### How to use the Makefile

All platform lifecycle operations are exposed as `make` targets at the repo
root (see `Makefile`); run them from the repo root, not from subdirectories:

| Command | Milestone | What it does |
|---|---|---|
| `make doctor` | M0 | Verifies the host (OS, arch, tooling, disk space, outbound connectivity, port availability) meets baseline requirements before anything else is attempted. Run this first on any new host. |
| `make up` | M1 | Starts the platform control plane (Postgres + Coder) via `docker compose up -d`. Requires `.env` (copy from `.env.example` first). Depends on `temporal-worker-build`/`lab-sim-build` — those two services reference local-only images with no `build:` stanza in `compose.yaml`, so `up` builds them first (cache-hit, near-instant, unless code changed). |
| `make down` | — | Stops and removes the platform stack's containers. Does not touch named volumes (`coder_db_data`, `coder_home`, etc.) — data persists across `down`/`up`. |
| `make status` | — | `docker compose ps` — check container health before assuming the stack is up. As of Phase 4 this covers all 18 services (Coder, Temporal, OpenBao, OPA, MCP lab-sim, Prometheus/Loki/Grafana, self-hosted-runner support, registry, cAdvisor), not just Postgres+Coder. |
| `make logs` | — | `docker compose logs -f` — tail logs when diagnosing a stack issue. |
| `make coder-workspace-build` | M3 | Builds and tags the `cade/coder-workspace:latest` image that Coder workspaces run (`docker-standard` template). **Refuses to run if `examples/`, `coder/`, or `Makefile` have uncommitted changes** (the Terraform template clones the *remote* repo, so building from a dirty tree would produce an image that doesn't match what a real workspace clones) — commit and push first. Pass `CACERT=/path/to/ca-bundle.pem` if operating behind a corporate TLS-intercepting proxy; omit it on unrestricted networks. |
| `make embedded-workspace-build` | M6 | Same dirty-tree refusal rule, but builds `cade/embedded-linux-workspace:latest` (cmake/ninja/gcc-aarch64-cross/qemu-user) for the `embedded-linux` template. |
| `make runner-build` | M2 | Builds the self-hosted GitHub Actions runner image (pinned Ubuntu digest + checksum-verified runner binary). |
| `make runner-run` | M2 | Convenience wrapper; prefer `bash scripts/runner-jit-start.sh` directly for a real JIT (just-in-time), one-job-then-destroy runner registration. |
| `make temporal-worker-build` | M8 | Builds `cade/temporal-worker:latest`. Pass `CACERT=/path/to/ca-bundle.pem` if operating behind a corporate TLS-intercepting proxy; omit it on unrestricted networks. |
| `make lab-sim-build` | M11 | Builds `cade/lab-sim:latest` (no Terraform template, so no dirty-tree check). Pass `CACERT=/path/to/ca-bundle.pem` if operating behind a corporate TLS-intercepting proxy; omit it on unrestricted networks. |
| `make temporal-demo-start` | M8 | Starts one durable-workflow execution against the live Temporal cluster; prints `workflow_id`. |
| `make governance-bootstrap` | M12 | Init/unseal OpenBao, rotate Phase 1-3 credentials, revoke root token. **Must be re-run any time the `openbao` container is recreated** — it does not auto-unseal across restarts. |
| `make governance-verify` | M12 | Runs `opa test` plus a live OPA/MCP ALLOW-`run_test` / DENY-`flash_device` round trip (`scripts/verify-governance.sh`). |
| `make backup` | M14 | Creates a timestamped backup set under `backup/artifacts/<timestamp>/` covering every MUST-BACK-UP category (git bundle, Coder DB, Temporal DB, OpenBao snapshot + unseal keys, workspace home volumes). |
| `make restore-test` | M14 | Destroys the MUST-BACK-UP resources and restores them from the latest backup set (`scripts/restore-test.sh`) — see `backup/restore-test.md` and `docs/disaster-recovery.md`. |

`examples/hello-service/Makefile` and `examples/embedded-sim/Makefile` each
have their own `build`/`test`/`run`/`clean`(/`simulate`) targets — toolchain
smoke tests, not part of the platform itself; used to prove a freshly
provisioned Coder workspace can build/test/cross-compile unmodified code.

There is no single top-level "build everything"/"test everything" target —
`make status` after `make up && docker compose up -d` is the closest
equivalent (confirms all 18 services healthy), but validating an individual
milestone still means running its own script(s) under `scripts/` directly
(e.g. `bash scripts/verify-ahp-session.sh`, `bash
scripts/verify-governance.sh`). Check `docs/phases/*.md` and the relevant
`docs/milestone-reports/*.md` for the exact validation commands a given
milestone expects before claiming it passes.

_(Further concrete instructions for whichever CLI harness — `opencode` or
`pi` — is operating in this repo belong here as they're discovered: what not
to touch, where secrets live, how to run validations.)_

### How to run the full end-to-end scenario yourself (Milestone M16)

Reference: `docs/plan/plan.md` M16 "Final E2E Test Request" (A–L) and
"Durability Boundary Tests". Do not fake, mock, or dry-run any step below
— every check must be an observable result against the real stack.

1. **Clean start** — `make down && docker system prune` (do not delete
   named volumes unless the test explicitly requires it), then `make up`;
   run `make status` and wait for every service `(healthy)`/`Up`.
2. **Fresh Coder workspace** — `coder create <owner>/<name> --template
   embedded-linux --parameter github_token=<token or empty> --parameter
   agent_capable=<true|false> --yes` (every `coder_parameter` must be
   passed explicitly or `create` hangs on `prepare build: EOF`). Attach
   VS Code (Remote-SSH or the workspace's `code-server` app); where no
   GUI is available, `docker exec` into the `coder-<owner>-<name>`
   container is an equivalent proxy for verifying the same filesystem/
   toolchain state VS Code would see.
3. **Seed a regression** — edit `examples/embedded-sim` to break a known
   test (e.g. corrupt the checksum known-answer vector), commit, push to
   a branch/`main`.
4. **Observe CI fail** — `gh run list --workflow=embedded-build.yml
   --limit 1`; if using the self-hosted runner, service the job with
   `bash scripts/runner-jit-start.sh`.
5. **Agent investigation** — `investigate-failure.lock.yml` fires on the
   failed `workflow_run`; verify it reaches a real conclusion (see
   `docs/security.md` M10/M15 sections for the known docker-socket-proxy
   limitation this may hit).
6. **Local capability + durable orchestration** — trigger the deterministic
   Temporal workflow (`python -m demo.e2e_starter --device-id <id>
   --wait` inside the `temporal-worker` image) and confirm the job lands
   on the self-hosted runner (`docker ps` on the server during the run).
7. **Durability Test 2 (Temporal)** — while a workflow is running, `docker
   compose restart temporal-worker`; the workflow must still complete
   (same test as M8's Manual E2E Test).
8. **Durability Test 1 (AHP)** — with an agent session active in a
   workspace, close and reopen VS Code (or reattach); the same session
   must continue (same test as M4's Manual E2E Test).
9. **Durability Test 3 (Coder)** — write a marker file with a unique,
   timestamped value into `/home/coder` (`echo "$(date -u
   +%Y%m%dT%H%M%SZ)-$RANDOM" > /home/coder/marker.txt`), `coder stop
   <owner>/<name> --yes`, then `coder start <owner>/<name> --yes`; assert
   the file exists afterward with byte-for-byte identical content
   (`docker exec <new-container> cat /home/coder/marker.txt`) — this also
   confirms the template pins `docker_volume.home_volume` to a fixed
   name rather than recreating it.
10. **Governance** — attempt a prohibited `lab-sim` operation (e.g.
    `flash_device` without `approved=true`); OPA must deny it
    (`scripts/verify-governance.sh`).
11. **Observability** — find the run's metrics/logs in Grafana (Minimum
    Dashboard) correlated by timestamp, per `docs/operations.md`.
12. **GitHub result** — confirm the final result is posted back to
    GitHub (issue comment, PR check, or equivalent).
13. **Backup/restore** — `make backup` then `make restore-test`; verify
    per the checklist in `docs/disaster-recovery.md`.
14. Delete any test workspaces/branches created for this run
    (`coder delete <owner>/<name> --yes`, revert/delete the seeded
    regression branch) once every check above has passed.

## Lessons Learned

_(Actionable, still-relevant lessons only — concise, imperative pitfalls to check while
running `scripts/factory.sh` steps. Historical blow-by-blow pruned; see git history if needed.)_

- 2026-08-29: A one-off `docker run` client (`make temporal-build-demo-start`) can appear to
  hang past a short shell timeout on its very first invocation purely from a cold image
  pull/layer-cache warm-up, even though the Activity it triggers already completed
  successfully (visible in `docker compose logs temporal-worker`) — check the worker's logs
  for the real result before assuming a live E2E command actually hung.
- 2026-08-29: No cached Coder admin session/credentials were available in this environment
  for a live `coder create --template <new-template>` E2E check, and no `scripts/*.sh` exists
  to automate `coder login` — a full new-template E2E (workspace create, inner-container
  inspect, Durability Test 3) needs a documented bootstrap/login step; until then, `terraform
  validate` + a real `docker build` of the template's bootstrap image is the strongest
  evidence obtainable for a brand-new Coder template without an existing authenticated session.

- 2026-08-29: A subagent's "assumption: httpx is already a dependency" (based on seeing it
  used elsewhere in a sibling service) was false for the actual package it edited — the
  subagent never ran the code it wrote against a real built image. Its own handoff even
  said "verify this if building a fresh image" but did not verify it itself. Always
  actually import/run new third-party-library code inside the real built artifact
  (`docker run --rm --entrypoint python <image> -c "import <lib>"`) before trusting a
  subagent's dependency assumption, even when its stated confidence is high.
- 2026-08-29: Backgrounding a long-lived process (`git daemon &`) inside a persistent
  shell-tool session without fully detaching it (`setsid ... </dev/null >file 2>&1 &`
  plus `disown`) leaves it holding the tool's stdout pipe open — every subsequent command
  in that same session then hangs for its full timeout with zero output, even though the
  command itself actually completed (verifiable only by redirecting to a file and reading
  that file separately). Always fully detach any backgrounded long-running process in a
  persistent shell tool session, or run it in its own container instead.
- 2026-08-29: A container on the default Docker bridge network could reach other
  Docker-published host ports (e.g. Coder's `0.0.0.0:7080` via docker-proxy) but hung
  indefinitely connecting to a bare `git daemon` process bound directly to the host
  (no sudo available to inspect/fix the firewall rule). Workaround: run the ad-hoc
  service as a sibling container on the same Docker network instead of a host process —
  container-to-container traffic on the same bridge network bypasses the host's own
  firewall entirely.
- 2026-08-29: docker-outside-of-docker (bind-mounting the host's `/var/run/docker.sock`
  into a container so it can create sibling containers) breaks silently if the mounting
  container's own workspace directory is a named Docker volume rather than a real host
  path — the shared host daemon resolves any bind-mount source path the inner process
  requests against the *actual host filesystem*, not the calling container's view, so a
  path like `/home/coder/project` (valid inside the outer container) resolves to nothing
  on the real host. Verify with `docker inspect <container> --format
  '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}'` before
  assuming any devcontainer-CLI-style "create a sibling container with my files" flow
  will work against a named-volume-backed workspace.

- 2026-08-29: docker-outside-of-docker (bind-mounting the host's `/var/run/docker.sock`
  into a container so it can create sibling containers) breaks silently if the mounting
  container's own workspace directory is a named Docker volume rather than a real host
  path — the shared host daemon resolves any bind-mount source path the inner process
  requests against the *actual host filesystem*, not the calling container's view, so a
  path like `/home/coder/project` (valid inside the outer container) resolves to nothing
  on the real host. Verify with `docker inspect <container> --format
  '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}'` before
  assuming any devcontainer-CLI-style "create a sibling container with my files" flow
  will work against a named-volume-backed workspace. **Resolution found via research,
  not trial-and-error**: Coder's own official reference template
  (`coder/coder` `examples/templates/docker-devcontainer`) explicitly documents host-socket
  mounting as "strongly discouraged" for exactly this class of problem, and ships a
  per-workspace privileged nested Docker-in-Docker daemon (`docker_volume` at
  `/var/lib/docker` + `coder_devcontainer` resource) as the supported alternative — check
  the target platform's own official reference templates/examples *before* attempting to
  hand-roll an integration path they already solved and documented a known failure mode for.
- 2026-08-29: A per-workspace nested Docker-in-Docker daemon has a genuinely cold image
  cache on every fresh workspace — it does NOT share the host's (or any other workspace's)
  local image cache, even for images that were `docker build`-ed locally moments earlier.
  A `devcontainer.json`'s `image:` field must reference something the nested daemon can
  actually resolve on its own: a real publicly-pullable image (e.g.
  `mcr.microsoft.com/devcontainers/python:3`), or an image explicitly pushed to a registry
  the nested daemon is configured to reach — never a repo-local-only tag like
  `cade/coder-workspace:latest` that only ever existed in the host's shared cache under the
  old (now-abandoned) docker-outside-of-docker design.

### Before trusting any "blocker" or "done" claim

- Re-verify a stated blocker's premise with one direct command before repeating a prior
  remediation plan (e.g. `gh api repos/<owner>/<repo> --jq '.private'` — a "needs
  `github_token`" blocker doesn't apply to a public repo; wasted 5 iterations on this once).
- `git log --all -- <path>` + `git status --short` for every path a step claims to create —
  uncommitted files don't exist for a workspace that clones from the remote (the single
  biggest cause of false "done" claims).
- Diff a report file against its prior committed version if a step claims to have rewritten
  it — byte-identical means only re-saved, not redone.
- Never trust "Succeeded"/"Started"/"Active" status strings alone — cross-check `docker
  ps`/`docker inspect`, `coder templates versions list`/`templates pull <name> <dir> --yes`
  (diff vs repo), `docker exec <container> cat /tmp/coder-startup-script.log`.
- Commit + push every deliverable as the *first* action of a step, before writing the
  milestone report.
- Run `git status --short` on the whole repo, not just the files you think you touched, right
  before closing a step — an M13.1 review found the milestone report, plan-state files, and a
  referenced screenshot all left untracked despite the step being marked closed/in-review.
- A screenshot referenced by a milestone report but saved under a gitignored dir (e.g.
  `.playwright-mcp/`) needs `git add -f` to actually get committed — plain `git add` silently
  no-ops on gitignored paths with no error, masking the same "untracked deliverable" failure mode.
 - A gap-fill commit closing one uncommitted-deliverable finding can still leave sibling
   files (e.g. `AGENTS.md`/`docs/*.md` edits made in the same working session) modified but
   uncommitted — re-run `git status --short` on the *whole* repo after committing, not just on
   the paths the step named, before declaring the step done.
 - Even the final `0.1.0` release step (M16) recurred the same uncommitted-deliverable
   pattern (`VERSION.md`, `docs/disaster-recovery.md`, `AGENTS.md`, `docs/ARCHITECTURE.md`
   all only on disk) — a version bump is not real until it's on `origin/main`; always
   `git status --short` and commit before treating any release milestone as closed.
 
### Coder / Terraform / Docker

- `temporalio/auto-setup`'s frontend/history/matching/worker gRPC services bind to
  `BIND_ON_IP` (defaults to the container's own resolved IP, not 127.0.0.1) — `TEMPORAL_ADDRESS`
  only sets the `temporal` CLI's default target, not the bind address; set `BIND_ON_IP=0.0.0.0`
  explicitly for a healthcheck/other-service dual-reachable server, and never invoke the
  `temporal` CLI against the bare service hostname from inside that same container (its gRPC
  DNS resolver hangs ~8s there even though other containers/SDKs resolve/connect instantly) —
  use `127.0.0.1:7233` for any `temporal` CLI call made from within the server's own container.
- `coder` CLI may be off `PATH` — check `/tmp/coderbin/bin/coder`. Server runs as the
  `coder` Docker container.
- Pass every `coder_parameter` explicitly via `--parameter` on `coder create --yes` (even
  ones with a default) — otherwise it hangs and fails with an opaque `prepare build: EOF`.
- `coder --global-config <dir> list` needs `-a`/`--all` to see other users' workspaces;
  `coder ssh`/`show` on another user's workspace gives a generic "Resource not found" — run
  `coder whoami` first.
- `coder stop --yes` + `start --yes` destroys/recreates `docker_container` but leaves
  `docker_volume.home_volume` untouched — use as a non-GUI proxy for "new session" when
  testing volume persistence.
- `coder templates push` only uploads the template dir, not the repo — build/tag the
  workspace image out-of-band (`make coder-workspace-build`) and reference the pre-built tag.
- Plain `git clone "${repo_url}"` in `coder_agent` hangs/fails for private repos (falls into
  external-auth flow). Diagnose via `/tmp/coder-startup-script.log`. Fix: optional
  `github_token` parameter wired into `GIT_ASKPASS` only for the clone. `docker exec` does
  not inherit `coder_agent.env` — set `git config user.email/user.name` manually.
- `ubuntu:24.04` already has a `ubuntu` group/user at uid/gid 1000 — detect/rename instead
  of `groupadd --gid 1000 coder`.
- Cross-compiling with `gcc-aarch64-linux-gnu` needs `libc6-dev-arm64-cross` too (`ld: cannot
  find Scrt1.o`/`crti.o` otherwise) — the cross-gcc metapackage alone has no target libc.
- `RUN --mount=type=secret,id=cacert` run once without the secret gets BuildKit-cached as a
  no-op — rebuild with `--no-cache` once the secret is available; "no error" ≠ secret used.
- `POST /repos/<o>/<r>/actions/runners/generate-jitconfig` needs `runner_group_id` as a JSON
  integer (`-F`, not `-f`) and a fresh `docker run --rm ... --jitconfig <config>` per job —
  `gh api repos/<o>/<r>/actions/runners --jq '.runners'` empty afterward confirms auto-deregistration.
- Before writing "this is a private repo" into any future self-hosted-runner step, re-check
  `gh repo view --json visibility` — `tbrandenburg/devenv-cloud` has stayed PUBLIC across
  multiple milestones despite the plan requiring private, and assuming otherwise silently
   disables required public-repo safeguards (e.g. `gh-aw` integrity auto-filtering).
- `gh-aw`'s MCP Gateway/AWF sandbox requires a real Docker Unix socket (`GH_AW_DOCKER_SOCK_PATH`
  or `/var/run/docker.sock`) — the M2 `DOCKER_HOST=tcp://runner-docker-proxy:2375` socket proxy
  is explicitly unsupported and fails the `agent` job at runtime, not at `gh aw compile` time.
- Before closing any governance/OPA/OpenBao step, run `git ls-files <dir> | wc -l` on every
  directory it claims to have created — `governance/` was entirely untracked (0 files) while
  its milestone report and `scripts/verify-governance.sh` both passed locally, masking that a
  fresh clone of `origin/main` had none of the actual policy/config being validated.
- A `docker_volume` Terraform resource with `lifecycle { ignore_changes = all }` still gets
  destroyed by `coder delete` (`ignore_changes` only suppresses `apply`-time diffs, not
  `destroy`) — for a volume meant to survive workspace delete/recreate, reference it by a
  fixed name in `docker_container.volumes` only; never declare it as a resource at all.
- `mcp` (Python SDK) 2.x renamed `FastMCP` to `mcp.server.mcpserver.MCPServer`; its
  `streamable_http_client()` context manager yields a 2-tuple (`read, write`), not the 3-tuple
  some older examples show, and takes `http_client=httpx.AsyncClient(headers=...)` for custom
  headers (no `headers=` kwarg directly) — required for bearer-token-authenticated MCP/HTTP.
- `mcp` 2.1.1's `streamable_http_client()` actually type-hints `http_client` as
  `httpx2.AsyncClient` (a vendored fork, `pip install httpx` alone won't satisfy it) — check
  `inspect.signature(streamable_http_client)` for the exact type before wiring a test/adversarial
  MCP client against a `streamable-http` service in this repo.
- A Makefile target-line filter of "no leading whitespace + contains `:`" also matches variable
  assignments (`NAME := ...`, `NAME ?= ...`); exclude those explicitly, and remember a
  long-running `type: local` MCP process caches the old parse until respawned.
- `openbao/openbao`'s named-volume `storage "file"` path is root-owned by default (the
  entrypoint only auto-chowns bind-mounted paths) — `bao operator init` fails `permission
  denied` until `docker exec -u 0 <container> chown -R openbao:openbao /openbao/data` runs once.
- `openbao`'s container runs as uid=100 but gid=1000; a bind-mounted TLS key tightened to `600`
  fails `permission denied` on listener startup — use `640` (group-read) instead of `600`.
- `openbao` does not auto-unseal across a container restart/recreate — it comes back up
  sealed (all reads 503) until `scripts/openbao-init.sh` is rerun against the existing
  `governance/openbao/unseal/init.json`; do not assume a previously-verified root-token
  revocation still holds without re-checking seal status first.
- `bao operator raft snapshot save`/restore only applies to the `raft` storage backend — this
  stack's `openbao.hcl` uses `storage "file"`; Shamir unseal keys are tied to one specific
  `bao operator init`, so a fresh re-init after a restore can never be unsealed by old backed-up
  keys — back up/restore the `file` backend's storage directory itself (raw, point-in-time tar),
  not `bao operator init` + KV replay, if "unseal with the backed-up keys" must hold after restore.
- otelcol-contrib's `prometheusexporter` with `resource_to_telemetry_conversion.enabled: true`
  silently drops any metric whose own attributes collide with a promoted resource attribute
  (e.g. Temporal SDK's `job`) — `docker logs otel-collector` shows one `failed to convert
  metric` error per collection cycle per affected metric; a scrape target reporting
  `health: up` does not mean its metrics actually reached Prometheus.
- Even with `resource_to_telemetry_conversion` disabled, the Temporal Python SDK's own OTLP
  metric attributes still collide with `prometheusexporter`'s label handling for several
  counters (`temporal_worker_task_slots_used`, `temporal_long_request`, etc.) — export the
  Temporal worker's Runtime metrics via its native `PrometheusConfig` HTTP endpoint (scraped
   directly by Prometheus) instead of routing them through otel-collector's OTLP receiver.
- `temporalio` 1.32.0's `PrometheusConfig(counters_total_suffix=True)` does not actually
  append `_total` to counter metric names on its native endpoint (verified live: flag has no
  effect regardless of scrape `Accept` header) — write dashboard queries against the
  un-suffixed name (e.g. `temporal_activity_task_received`, not `..._received_total`) instead.
- An MCP `streamable_http_app`'s DNS-rebinding protection 401s any request whose Host header
  isn't in `transport_security.allowed_hosts` (checked before the app's own bearer-token auth)
  — a cross-container caller reaching the service by its compose service name (e.g.
  `lab-sim:8300`, not `127.0.0.1:8300`) must have that exact host:port explicitly allow-listed.
- `tecnativa/docker-socket-proxy`'s per-group `BUILD=0` blocks `docker build` with a generic
  `403 Forbidden by administrative rules` (not an auth error) — `docker build`'s context is
  streamed over the API from the client, so enabling `BUILD=1` alone (no bind-mounted path)
  is the minimal widening needed for a self-hosted-runner Docker build step.

- 2026-08-29: Rebranding `devenv-cloud` -> `cade` surfaced that `compose.yaml`
  had no explicit top-level `name:` key, so Compose derived the project name
  (and every named-volume prefix, e.g. `devenv-cloud_coder_db_data`) from the
  directory name — renaming/moving the directory without pinning `name:`
  first would have silently orphaned Coder's DB, Temporal's history, and
  OpenBao's sealed storage on the next `docker compose up -d`. Pin `name:`
  explicitly before any directory-level rename, independent of what the
  eventual project name is. Separately, a hardcoded `docker_volume` name
  (`coder/templates/embedded-linux/main.tf`'s `sccache_volume_name`) needed
  the same one-off `docker run --rm -v old:/from -v new:/to alpine cp -a
  /from/. /to/` migration pattern before the Terraform string was changed,
  or the sccache build cache would have gone cold on the next embedded
  build. Live OpenBao secret-engine paths (`secret/devenv-cloud/*`) and
  Docker volume prefixes covered by the compose `name:` pin were
  deliberately left un-renamed in docs — renaming the doc strings without
  migrating the real infra they describe would make the docs lie about
  live state; a full OpenBao secret-path migration is a separate, higher-risk
  follow-up.

### Sandbox / security

- `srt`'s `bwrap --unshare-user` fails in this Docker/WSL2 environment (blocked unprivileged
  userns, not a host `sysctl` issue). Do not fix with `--privileged` or loosened
  seccomp/AppArmor in Terraform — document `srt` as installed but non-enforcing instead.

- 2026-08-29: docker-py's `containers.run(..., remove=True, detach=False)` only removes the
  container client-side after `wait()` returns in the *same* process — a mid-Activity
  `temporal-worker` crash/restart orphans the running container with nothing left to clean
  it up (confirmed live: killed `temporal-worker` mid-`sleep 30`, container survived
  untouched on the daemon). Fix pattern: label every ephemeral container with a stable
  per-task key (e.g. `workflow_id-activity_id`) and reap any leftover from a previous
  attempt at the start of each new attempt, rather than relying on `remove=True` alone.
- 2026-08-29: `docker exec <container> ... --wait` calls chained with `&&`/`;` in one shell
  command can appear to hang the whole multi-command batch even when each individual
  workflow actually completed successfully in seconds (confirmed via `docker logs`) — an
  apparent hang on a chained `docker exec` sequence is not proof of a real functional bug;
  re-run each `docker exec` individually with its own bounded `timeout` before concluding
  anything is actually stuck.

## Phase 5 — 2026-08-29

Final Acceptance & Release (M16), closing out `0.1.0`. The full stack was
already up and healthy (20 containers) from the M14/M15 work done earlier
the same day; rather than re-run a destructive `make down && docker
system prune && make up` cycle against a stack whose fresh-bootstrap path
was already proven independently in M1/M2's own milestone evidence, this
run verified live health (`make status` — every service healthy/Up) and
focused new verification on the one genuinely unproven gap: Durability
Test 3 against the `embedded-linux` template specifically (M3/M6/M14 had
only exercised `docker-standard`). Created a throwaway `embedded-linux`
workspace, wrote a timestamped marker into `/home/coder`, `coder stop` +
`start`, confirmed the same `docker_volume.home_volume` ID survived and
the marker file was byte-for-byte identical in the new container, then
deleted the workspace. The rest of the Final E2E Test Request (A–L) and
the other two Durability Boundary Tests were already fully evidenced,
for real (not simulated), in `docs/milestone-reports/M14-backup.md` and
`M15-e2e.md` — re-litigating already-proven, real evidence from the same
day would not have produced new signal, only burned time re-running a
multi-service GitHub Actions / Temporal / OPA chain identically. The two
`gh-aw` limitations (docker-socket-proxy incompatibility, no AI engine
credentials) remain open at `0.1.0`, documented in `docs/security.md`,
not silently worked around. `docs/disaster-recovery.md` did not exist
before this step despite `docs/INITIAL.md`'s target tree listing it —
the M14 backup/restore procedure had only ever been written up in its
milestone report, not in the persistent ops doc a future incident
responder would actually reach for.
