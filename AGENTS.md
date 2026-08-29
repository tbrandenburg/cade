# AGENTS.md — devenv-cloud

Instructions and accumulated knowledge for any AI agent (human or automated) working in this repository. Update this file at the end of every phase per `docs/phases/README.md`.

## How to use this file

- Read this file before starting work on any phase or milestone.
- Read `docs/ARCHITECTURE.md` alongside it — a condensed C4-model (Context/Container/Component) view of the platform, based on `docs/devenv-cloud.png` and `docs/INITIAL.md` Section 2. Use it for quick orientation; `docs/INITIAL.md` remains authoritative for details.
- Update it before closing out a phase — do not leave it stale.
- Keep entries dated and attributed to a phase/milestone so history stays traceable.
- Prefer appending to "Lessons Learned" over rewriting history; only edit "Guidelines" when a rule changes.

## Purpose of this repository

devenv-cloud is a Docker-first, single-repository private developer platform:
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

## Agent Instructions

### How to use the Makefile

All platform lifecycle operations are exposed as `make` targets at the repo
root (see `Makefile`); run them from the repo root, not from subdirectories:

| Command | Milestone | What it does |
|---|---|---|
| `make doctor` | M0 | Verifies the host (OS, arch, tooling, disk space, outbound connectivity, port availability) meets baseline requirements before anything else is attempted. Run this first on any new host. |
| `make up` | M1 | Starts the platform control plane (Postgres + Coder) via `docker compose up -d`. Requires `.env` (copy from `.env.example` first). |
| `make down` | — | Stops and removes the platform stack's containers. Does not touch named volumes (`coder_db_data`, `coder_home`) — data persists across `down`/`up`. |
| `make status` | — | `docker compose ps` — check container health before assuming the stack is up. |
| `make logs` | — | `docker compose logs -f` — tail logs when diagnosing a stack issue. |
| `make coder-workspace-build` | M3 | Builds and tags the `devenv-cloud/coder-workspace:latest` image that Coder workspaces run. **Refuses to run if `examples/`, `coder/`, or `Makefile` have uncommitted changes** (the Terraform template clones the *remote* repo, so building from a dirty tree would produce an image that doesn't match what a real workspace clones) — commit and push first. Pass `CACERT=/path/to/ca-bundle.pem` if operating behind a corporate TLS-intercepting proxy; omit it on unrestricted networks. |

`examples/hello-service/Makefile` has its own `build`/`test`/`run`/`clean`
targets — a toolchain smoke test, not part of the platform itself; used to
prove a freshly provisioned Coder workspace can build/test Python code
unmodified.

There is no single top-level "build everything"/"test everything" target —
each milestone/phase introduces its own validation script(s) under
`scripts/`, invoked directly (e.g. `bash scripts/verify-ahp-session.sh`), not
wrapped in `make` yet. Check `docs/phases/*.md` and the relevant
`docs/milestone-reports/*.md` for the exact validation commands a given
milestone expects before claiming it passes.

_(Further concrete instructions for whichever CLI harness — `opencode` or
`pi` — is operating in this repo belong here as they're discovered: what not
to touch, where secrets live, how to run validations.)_

## Lessons Learned

_(Actionable, still-relevant lessons only — concise, imperative pitfalls to check while
running `scripts/factory.sh` steps. Historical blow-by-blow pruned; see git history if needed.)_

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

### Sandbox / security

- `srt`'s `bwrap --unshare-user` fails in this Docker/WSL2 environment (blocked unprivileged
  userns, not a host `sysctl` issue). Do not fix with `--privileged` or loosened
  seccomp/AppArmor in Terraform — document `srt` as installed but non-enforcing instead.
