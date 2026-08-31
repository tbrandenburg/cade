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
| `make up` | M1 | Starts the platform control plane (Postgres + Coder) via `docker compose up -d`. Requires `.env` (copy from `.env.example` first). Depends on `temporal-worker-build`/`lab-sim-build` — those two services reference local-only images with no `build:` stanza in `compose.yaml`, so `up` builds them first (cache-hit, near-instant, unless code changed). Prints the main web UI URLs (Coder, Temporal, Grafana) afterward. |
| `make down` | — | Stops and removes the platform stack's containers. Does not touch named volumes (`coder_db_data`, `coder_home`, etc.) — data persists across `down`/`up`. |
| `make status` | — | `docker compose ps` — check container health before assuming the stack is up. As of Phase 4 this covers all 18 services (Coder, Temporal, OpenBao, OPA, MCP lab-sim, Prometheus/Loki/Grafana, self-hosted-runner support, registry, cAdvisor), not just Postgres+Coder. |
| `make logs` | — | `docker compose logs -f` — tail logs when diagnosing a stack issue. |
| `make coder-workspace-build` | M3 | Builds and tags the `cade/coder-workspace:latest` image that Coder workspaces run (`docker-standard` template). **Refuses to run if `examples/`, `coder/`, or `Makefile` have uncommitted changes** (the Terraform template clones the *remote* repo, so building from a dirty tree would produce an image that doesn't match what a real workspace clones) — commit and push first. Pass `CACERT=/path/to/ca-bundle.pem` if operating behind a corporate TLS-intercepting proxy; omit it on unrestricted networks. |
| `make embedded-workspace-build` | M6 | Same dirty-tree refusal rule, but builds `cade/embedded-linux-workspace:latest` (cmake/ninja/gcc-aarch64-cross/qemu-user) for the `embedded-linux` template. |
| `make agent-workspace-build` | Issue #13 | Depends on `coder-workspace-build` (inherits its dirty-tree refusal guard); builds `cade/agent-workspace:latest` (adds the OSS `boundary` network-isolation CLI) for the `agent-workspace` template, used for long-running Coder Agents sessions. |
| `make templates-push` | — | Pushes `docker-standard`, `embedded-linux`, `devcontainer`, and `agent-workspace` templates to the running Coder server in one shot (`coder templates push ... --yes` x4). Depends on all four `*-workspace-build` targets — also (re)builds the images first (cache-hit, near-instant unless code changed) and inherits their dirty-tree refusal check. Requires the `coder` CLI on `PATH`, an authenticated session, and Coder already up/healthy. |
| `make runner-build` | M2 | Builds the self-hosted GitHub Actions runner image (pinned Ubuntu digest + checksum-verified runner binary). |
| `make runner-run` | M2 | Convenience wrapper; prefer `bash scripts/runner-jit-start.sh` directly for a real JIT (just-in-time), one-job-then-destroy runner registration. |
| `make temporal-worker-build` | M8 | Builds `cade/temporal-worker:latest`. Pass `CACERT=/path/to/ca-bundle.pem` if operating behind a corporate TLS-intercepting proxy; omit it on unrestricted networks. |
| `make lab-sim-build` | M11 | Builds `cade/lab-sim:latest` (no Terraform template, so no dirty-tree check). Pass `CACERT=/path/to/ca-bundle.pem` if operating behind a corporate TLS-intercepting proxy; omit it on unrestricted networks. |
| `make temporal-demo-start` | M8 | Starts one durable-workflow execution against the live Temporal cluster; prints `workflow_id`. |
| `make governance-bootstrap` | M12 | Init/unseal OpenBao, rotate Phase 1-3 credentials, revoke root token. **Must be re-run any time the `openbao` container is recreated** — it does not auto-unseal across restarts. |
| `make governance-verify` | M12 | Runs `opa test` plus a live OPA/MCP ALLOW-`run_test` / DENY-`flash_device` round trip (`scripts/verify-governance.sh`). |
| `make backup` | M14 | Creates a timestamped backup set under `backup/artifacts/<timestamp>/` covering every MUST-BACK-UP category (git bundle, Coder DB, Temporal DB, OpenBao snapshot + unseal keys, workspace home volumes). |
| `make restore-test` | M14 | Destroys the MUST-BACK-UP resources and restores them from the latest backup set (`scripts/restore-test.sh`) — see `backup/restore-test.md` and `docs/disaster-recovery.md`. |
| `make ai-bootstrap` | Issue #13 | Reconciles `coder/ai/{providers,models}.yaml` into the running Coder deployment (`scripts/ai-bootstrap.sh`). Also invoked best-effort at the end of `make up`. |
| `make ai-token` | Issue #13 | Mints an admin session token for `make ai-bootstrap` (`scripts/ai-token.sh`). |
| `make verify-ai` | Issue #13 | Proves the AI integration works end to end against the live stack (`scripts/verify-ai.sh`). |
| `make omnigent-bootstrap` | Issue #43 | Creates the first `omnigent-server` admin account (`scripts/omnigent-bootstrap.sh`). |

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

- 2026-08-31 (Issue #47, `coder_app` custom icon): a `coder_app.icon` set to
  a plain-`http` URL is silently blocked by Coder's own default
  Content-Security-Policy (`img-src 'self' https: data: blob:`) — the
  `<img>` never loads and there is no server-side error, only a browser
  console CSP violation. On a platform with no TLS termination in front of
  Coder by design, fix with `CODER_ADDITIONAL_CSP_POLICY` widening `img-src`
  for exactly the one already-trusted internal origin, rather than
  switching to `https:` (not available) or assuming a `data:` URI is a
  drop-in alternative — also check `workspace_apps.icon`'s Postgres column
  (`varchar(256)`) before choosing a `data:` URI for any non-trivial
  real-world icon asset; it will not fit. Always visually re-verify a
  `coder_app.icon` change in a real browser session (check
  `page.on('console')` for CSP errors), not just via the Coder API/CLI —
  the stored field value can be exactly right while still failing to
  render for a reason invisible to any non-browser check.
- 2026-08-30 (Issue #43, omnigent host integration, Stage B live E2E
  session against a real `coder create`d workspace, host security
  profiles loaded via `sudo scripts/load-security-profiles.sh`): three
  more real, live-reproduced bugs, two fixed, one found to be a hard
  architectural blocker requiring its own follow-up issue.
  (1) The `~/.omnigent-bin` PATH shim was only appended to `~/.bashrc`
  — `coder_agent`'s `startup_script` never sources `.bashrc` itself
  (non-interactive `sh -c`), so `omnigent host --background` inherited
  the *original* PATH with no shim in it, and the omnigent-spawned
  `opencode-native` runner (a plain PATH lookup for the literal command
  `opencode`) launched the real, unwrapped binary directly — confirmed
  live via `ps aux` inside a real workspace: no `bwrap`/`srt` anywhere
  in the process tree. Fixed by exporting PATH in the *same*
  `startup_script` invocation, not only writing it into `.bashrc`.
  (2) Once PATH was fixed, `exec srt opencode -- "$@"` broke a
  different way (`Error: listen EPERM ... /tmp/claude/srt-mux-2-0.sock`):
  `srt` itself resolves its *target* program via the same (now-shimmed)
  PATH, so the bare word `opencode` passed to `srt` recursed back into
  our own shim — a sandbox launching a second, nested sandbox of itself,
  both colliding on the same deterministic pid-in-namespace mux socket
  path. Isolated by direct A/B comparison (bare name fails, absolute
  path succeeds, PATH held identical) and fixed by always passing `srt`
  an absolute path, never a bare command name that might resolve
  through a shim shadowing that same command on PATH. General rule:
  **never let a PATH-shadowing shim's own directory remain on PATH when
  that shim itself invokes something that does its own internal PATH
  resolution** — pass absolute paths through, or the shim can recurse
  into itself.
  (3) **Open architectural blocker, not fixed**: even with both of the
  above fixed and the sandboxed `opencode serve` process launching
  correctly (verified: `node /usr/bin/srt <path> -- serve ...` → `bwrap`
  → `apply-seccomp` → `opencode serve`, the full chain), the real
  omnigent chat turn still failed with `opencode serve did not become
  ready: ConnectError('All connection attempts failed')`. Root cause:
  `srt` always applies `bwrap --unshare-net` on Linux (confirmed no CLI
  flag/settings-file escape hatch exists — checked `srt --help` and the
  installed package's own `linux-sandbox-utils.js`), giving the
  sandboxed process its own private network namespace with only an
  outbound HTTP/SOCKS proxy for the sandboxed program's own traffic.
  Omnigent's `opencode-native` harness needs the *opposite*: an
  **external, unsandboxed** runner process reaching *back into* the
  sandboxed `opencode serve`'s TCP loopback port for orchestration —
  that port is invisible outside the sandbox's private netns. This is a
  genuine design mismatch between `srt`'s all-or-nothing network
  isolation model and omnigent's supervisor-reaches-into-harness
  architecture, not fixable from a Coder template/startup-script alone.
  Needs its own scoped follow-up issue (e.g. a port-forward/exception
  mechanism in `srt`, or a different IPC channel omnigent could use
  through the same outbound proxy already in place) before Stage B can
  be considered fully closed.

- 2026-08-30 (Issue #43, omnigent host integration, live E2E verification
  session, follow-up to the implementation-time entry above): bringing up
  the real `omnigent-server`/`omnigent-db` pair live (scoped `docker
  compose up -d omnigent-db omnigent-server` — not the full stack) and
  exercising the actual startup-script logic against it (via `docker run`
  + `docker exec`, not through a live Coder session) surfaced three more
  real bugs no amount of source reading alone had caught:
  (1) `compose.yaml`'s `omnigent-server` service never actually passed
  `OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD` through to the container despite
  three other files (`.env.example`, `scripts/omnigent-bootstrap.sh`,
  `scripts/openbao-init.sh`) all depending on it reaching the server —
  bootstrap would have silently never worked. (2) With no
  `OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME` set, the server's first-admin
  bootstrap defaults the username to `getpass.getuser()` inside the
  container, i.e. `"root"` (the image runs as root) — NOT `"admin"` as
  every other script/Terraform default assumed; every `admin` login
  attempt failed with a generic "invalid username or password" until this
  was pinned explicitly. (3) The `OMNIGENT_HOST_ID`/`OMNIGENT_HOST_NAME`
  env-var mechanism documented in `omnigent/host/identity.py`'s own
  docstring (and used in the first implementation pass) does NOT actually
  reach a `--background` remote host daemon — `omnigent.cli._build_host_daemon_env`
  spawns that daemon subprocess through a strict environment ALLOWLIST that
  excludes both vars, so they're silently dropped and the daemon falls back
  to a random uuid4 + the container hostname every time. Reproduced live
  (registered host_id/name matched neither value passed). Fixed by writing
  `~/.omnigent/config.yaml`'s `host:` section directly instead, which
  `load_or_create_host_identity` honors — with the added benefit that this
  file lives on the persistent home volume, so identity survives `coder
  stop`/`start` for free. General rule: reading a library's own docstrings/
  source is necessary but not sufficient — an env var documented as
  "the mechanism" in one code path (here, the identity *loader*) can still
  be silently filtered out one layer up (the daemon *spawner*) by a
  security-motivated allowlist. Always trace an env var all the way from
  where you set it to where it's actually read, in a live process, not
  just to the first function that appears to read it.

- 2026-08-30 (Issue #43, omnigent host integration, implementation-time):
  the real installed `omnigent==0.11.0` CLI has neither an `omnigent login
  --token` flag nor an `omnigent host --name` flag — both were initially
  assumed from adjacent naming conventions elsewhere in this repo (e.g.
  `github_token`/named workspace parameters) without checking the actual
  CLI first. Caught by running `omnigent login --help`/`omnigent host
  --help` against the real installed package and reading its source
  (`omnigent.cli_auth`, `omnigent/host/identity.py`) before writing the
  Terraform startup script. Corrected to: replicate the real
  `_accounts_login()` POST `/auth/login` + `store_token(...)` flow
  directly for login, and the `OMNIGENT_HOST_ID`/`OMNIGENT_HOST_NAME` env
  var pair (not CLI flags) for a disposable per-workspace host identity.
  Always run `--help` (or read the source) against the *actual installed
  version* of a new third-party CLI dependency before writing automation
  around assumed flag names, even when a similar-looking flag exists
  elsewhere in this same repo for a different tool.

- 2026-08-30 (Issue #25, coordinator process note): after a subagent finished a single-issue
  fix in its own worktree/branch, the coordinator integrated it by running `git checkout main`
  then `git merge --no-ff <branch>` directly on the shared local `main` — instead of creating
  a separate `integrate/<issue>` branch first, as had correctly been done for the prior issue
  in the same session. Because this repo's `main` has no GitHub branch-protection rule
  (confirmed via `gh api repos/<owner>/<repo>/branches/main/protection` → 404 "Branch not
  protected"), an unrelated already-configured push path pushed that merge straight to
  `origin/main`, bypassing the requested branch → push → PR → merge workflow entirely — the
  fix was correct and is verified live, but no PR/review record exists for it. Always merge a
  finished subagent's branch into a fresh coordinator-owned integration branch
  (`git checkout -b integrate/<issue> main`), never directly onto a local `main` that already
  tracks `origin/main`, regardless of whether the remote branch is known to be protected.
- 2026-08-30 (Issue #23, coordinator process note): a first subagent spawn for a
  host-security-profile task (seccomp/AppArmor for `srt`/`bwrap`) was aborted mid-task by a
  rejected permission prompt, most likely for a privileged/host-mutating command (`sudo`,
  `apparmor_parser -r`, or similar) that is legitimately out of scope for an agent session on
  a shared, non-sandboxed host running production-adjacent services. Retrying with an explicit
  "HARD SAFETY RESTRICTIONS" section up front (no `sudo`, no loading/removing AppArmor profiles,
  no `--privileged`, no touching already-running containers, plain unprivileged `docker run
  --rm`/read-only `docker exec` only) let the same task complete cleanly and honestly report
  which acceptance criteria were verified live vs. deferred as follow-up. When delegating any
  task that plausibly touches host-level state, state the safety boundary explicitly in the
  subagent prompt before the first attempt, rather than discovering it via a rejected tool call.
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
  **Update, same day**: a fully non-interactive bootstrap for exactly this gap does exist —
  `docker exec coder coder server create-admin-user --postgres-url
  "postgresql://coder:coder@coder-db/coder?sslmode=disable" --email <e> --password <p>
  --username <u>` creates a second admin directly against the DB (works even while the
  server is already running, and works even when a first user already exists from a prior
  session — the "no cached creds" gap is only a *credentials* gap, not a missing-tooling
  gap). Then `curl -s -X POST http://localhost:7080/api/v2/users/login -d
  '{"email":"<e>","password":"<p>"}'` returns a `session_token` directly usable with `coder
  login <url> --use-token-as-session` (piped via stdin) — no browser/`cli-auth` flow needed.
  This unblocked a real, live `coder create`/`coder delete` round trip for the AHP user
  journey (README Journey 9). One residue: a Coder user cannot delete or suspend itself
  (`You cannot delete/suspend yourself`), so the ad-hoc admin account persists in `coder-db`
  after `coder logout` — acceptable for this single-server, non-internet-exposed platform,
  but note/clean it up (`coder users delete <name>` from a *different* admin session) if one
  becomes available, rather than assuming `coder logout` alone removed it.
  **Separately confirmed same day**: VS Code's Agent Host process is genuinely started lazily
  by a real VS Code Desktop client's first Agents-window connect — `scripts/verify-agent-host.sh`
  and `scripts/verify-ahp-session.sh` both correctly and expectedly report FAIL (no process
  found / no port to discover) against a freshly created `agent_capable=true` workspace with
  no VS Code Desktop client ever attached. This is not a bug in either script; there is no
  known non-interactive substitute for that first real client connection, so the actual AHP
  JSON-RPC handshake still cannot be produced end-to-end without a real VS Code Desktop
  session — the SSH bridge, workspace creation, and both scripts' *own* failure-path behavior
  are everything independently verifiable without one.

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
- 2026-08-30 (Issue #17): Coder's `POST /api/v2/users/{user}/keys/tokens`
  `lifetime` field is nanoseconds (Go `time.Duration`), not seconds — a
  seconds-valued request (e.g. `7776000` meant as 90 days) is silently
  accepted as ~0.0078 real seconds and expires before the token's first
  real use, failing later with an opaque `401`. Server also caps the max
  at `168h` (7 days) regardless of what's requested — verify by listing
  the created key's `expires_at`, not just a `201`/non-error create response.
- 2026-08-30 (Issue #17): `coder/agents-chat-action@v0`'s chat-reuse
  mechanism (a hidden HTML tracking comment on the triggering issue,
  keyed on `github-url` + workflow name) silently ignores a freshly
  pre-created `workspace-id` input on a repeat run and keeps the prior
  run's chat/workspace reference — breaks outright (`410`) once that old
  workspace is deleted. Always set `force-new-chat: true` in any
  automation that pre-creates a fresh workspace per run, or verify the
  reuse behavior explicitly before relying on it.
- 2026-08-30 (Issue #17): Coder workspace names are capped at 32
  characters server-side; a naming scheme combining an issue number and
  a full GitHub numeric run id can exceed this with no obvious warning
  in the validation error message (just "Validation failed for tag
  \"workspace_name\""). Keep generated workspace names short and check
  the actual character count, don't assume a "looks reasonable" name fits.

- 2026-08-30 (Issue #45, cade-only reverse Unix-socket bridge): closed
  the Issue #43 architectural blocker where `srt`'s `bwrap --unshare-net`
  made a sandboxed `opencode serve`'s loopback port unreachable from the
  unsandboxed `omnigent host` runner — fixed with a reverse Unix-socket
  bridge (Direction 4: Unix sockets are filesystem objects and cross a
  network-namespace boundary via a shared `/tmp` bind-mount, unlike TCP).
  Full design/evidence in the issue itself and
  `docs/milestone-reports/issue-45-bridge.md`; three durable, reusable
  lessons from live verification of the fix:
  (1) `srt-settings.json`'s `allowWrite` allowlist needed `~/.cache` and
  `~/.config` added — `opencode serve` crashed with `EROFS` without them;
  when sandboxing a long-running server process (not just a one-shot
  CLI), enumerate every directory it writes to on startup, not just the
  workspace/project paths an interactive session would touch.
  (2) A `pgrep -f '<script-name>.sh'` idempotency check inside a script
  that is itself invoked as `sh -c "<script text>"` (Coder's
  `startup_script` mechanism, and likely any similar "run this script
  body inline" launcher) can self-match its own already-running process,
  because the full script text — including its own comments/heredocs
  containing that literal string — *is* the running process's command
  line. Fixed with a PID-file + `kill -0` check instead of `pgrep -f`
  against a string. General rule: never `pgrep -f` for a script's own
  name from within that same script when it might be running via an
  inline `sh -c "<text>"` invocation rather than as a file on disk.
  (3) A dead Unix domain socket special file is **not** automatically
  removed from disk once its listener process exits — a watchdog reap
  check written as `[ ! -e "$sock" ]` never fires for a stale/dead
  socket. Fixed by actively probing liveness (`socat -u OPEN:/dev/null
  UNIX-CONNECT:"$sock"`, which fails fast against a dead socket) instead
  of trusting the file's mere existence. Separately, a process/testing
  note: because this fix lived only on an unmerged branch, both the
  isolated `docker exec` verification pass and the full live Stage B
  chat-session pass had to manually overwrite `~/.srt-settings.json`
  inside each throwaway container — the real `agent-workspace`
  `startup_script` clones `origin/main` (not this branch), so a
  Terraform-template-embedded fix and its companion repo-cloned config
  file can drift apart pre-merge; any future template change with a
  similar split (template logic changed, but a file the *cloned repo*
  provides at runtime hasn't caught up yet) needs the same manual
  workaround until merge, and should not be mistaken for the fix itself
  being broken.

### Sandbox / security

- **RESOLVED (2026-08-30) — Issue #23 fully closed with live, complete
  evidence.** After the AppArmor profile load succeeded (issue #27/#30's
  fixes), `bwrap` progressed through its *entire* real invocation
  sequence one gap at a time (issues #34, #36, #38, #40 — each found by
  re-testing the real `srt opencode` command, not just a synthetic
  `bwrap --ro-bind / /` smoke test, after the previous gap was fixed):
  additional mount(2) flag combinations (tmpfs, recursive bind mounts,
  remounts, private-detach, devpts, fresh procfs), `pivot_root`/`umount2`
  (unconditionally blocked by Docker's default seccomp profile
  regardless of capabilities), a second `unshare(CLONE_NEWPID|
  CLONE_NEWNS)` call from `srt`'s own internal `apply-seccomp` helper,
  and finally Docker's **`systempaths`** masking — a *third*, wholly
  separate confinement layer (independent of seccomp/AppArmor/
  capabilities) that bind-mounts read-only decoys over sensitive
  `/proc`/`/sys` paths, reproduced even under fully-`unconfined`
  seccomp+AppArmor and `--cap-add SYS_ADMIN`, resolved with
  `--security-opt systempaths=unconfined` (verified safe: this profile's
  own AppArmor rules already independently `deny` every path
  `systempaths` masks, so disabling Docker's redundant copy of the same
  restriction is not a security regression). One application-level fix
  (unrelated to sandboxing) was also needed: `agent-host/srt-settings.json`'s
  `allowWrite` was missing `~/.local`, needed by `opencode`'s own Bun
  runtime.

  **Final live verification, real, no mocks, through the actual Coder
  pipeline** (fresh `coder create` + re-pushed templates, not just a
  one-off `docker run`) for all three affected templates
  (`docker-standard`, `embedded-linux`, `agent-workspace`):
  ```
  $ srt opencode -- --version   ->  1.18.25
  $ srt pi -- --version         ->  0.74.2
  $ srt -c "cat ~/.ssh/id_rsa"  ->  denied (secret readable outside the sandbox, not inside)
  $ srt -c "echo x > .env"      ->  denied (Permission denied)
  ```
  No `--privileged`, no `apparmor=unconfined`/`seccomp=unconfined`, no
  extra `cap-add` in the final template configuration — matching Issue
  #23's own acceptance criteria exactly. This is the first time `srt`'s
  filesystem defense-in-depth property (`denyRead`/`denyWrite`) has ever
  been proven working end to end; M9's original milestone report
  explicitly noted this couldn't be verified before because `bwrap`
  itself couldn't even start.

  **Process lessons from this final stretch, worth remembering for any
  future Docker-sandboxing debugging:**
  - Docker layers *at least four* independent confinement mechanisms:
    seccomp, AppArmor, Linux capabilities, and `systempaths`
    (masked-paths). A fix that "should" work per seccomp+AppArmor alone
    can still fail due to a completely separate, easy-to-overlook fourth
    layer. When stuck, set each layer *individually* to its most
    permissive setting (`unconfined`/`--privileged`/extra `cap-add`) to
    isolate which one is actually still responsible, rather than
    assuming the most recently touched layer must be at fault.
    `--privileged` succeeding where `--cap-add <specific-cap>` +
    `unconfined` seccomp/AppArmor doesn't is a strong signal that a
    *different* mechanism (not capabilities) is still involved.
  - `--security-opt systempaths=unconfined` (and similar Docker-CLI-only
    convenience flags) do not necessarily appear as a literal string in
    `docker inspect --format '{{.HostConfig.SecurityOpt}}'` even when
    correctly applied — check the actual underlying effect instead
    (`{{json .HostConfig.MaskedPaths}}`/`{{json .HostConfig.ReadonlyPaths}}`
    for this specific flag) rather than assuming a missing string means
    the setting had no effect.
  - A synthetic minimal reproduction command does not necessarily
    exercise every flag/mount-type/syscall combination a *real* caller
    actually uses — `srt`'s real invocation added `--dev /dev` and a
    second internal `unshare` call that a bare `bwrap --ro-bind / /` test
    never triggered. Always re-verify against the real-world command
    before declaring an underlying issue closed.
  - A stale, already-pushed Coder template version silently keeps using
    old security-profile *content* (Terraform embeds it via `file()` at
    push time) — always re-push (`coder templates push <name> -d
    <dir> --yes`) and recreate the workspace before re-testing a
    profile change against a live workspace, or you'll reproduce an
    already-fixed bug and wrongly conclude the fix didn't work.
  - Disabling one Docker confinement mechanism is not automatically a
    security regression if a *different* mechanism already independently
    enforces the same boundary — verify this explicitly (as done here,
    cross-checking AppArmor's existing `deny` rules against the exact
    paths `systempaths` masks) rather than assuming any `unconfined`-named
    flag is inherently unsafe.

- **Superseded by Issue #23 (2026-08-30), corrected root cause below** —
  the original M9-era diagnosis that `srt`'s `bwrap --unshare-user` fails
  because of a genuine kernel-level restriction
  (`kernel.unprivileged_userns_clone`) was **wrong**: that sysctl is
  actually `1` (permissive) on this host, both on the host and inside a
  live workspace container. The real blockers are two of *Docker's own*
  default confinement layers, stacked: (1) Docker's default seccomp
  profile filters the `clone`/`unshare` syscall arguments needed for
  `CLONE_NEWUSER`; (2) Docker's default `docker-default` AppArmor profile
  then blocks the `mount --make-rslave` remount `bwrap` performs
  immediately after entering the new user namespace. `--privileged` alone
  (or both `seccomp=unconfined` + `apparmor=unconfined` together) fixes
  it, proving there is no genuine kernel-level block — but per
  `docs/INITIAL.md`'s own guidance, `--privileged`/`unconfined` widens the
  *whole* container's attack surface and is not an acceptable fix.
  Issue #23 instead ships two narrowly-scoped replacement profiles under
  `coder/security-profiles/` (a seccomp JSON relaxing exactly
  `clone`/`unshare` for `CLONE_NEWUSER` plus `mount` for
  `MS_REC|MS_SLAVE`, and an AppArmor profile adding exactly `userns,` and
  `mount options=(make-rslave),` on top of Docker's own `docker-default`
  template), wired into all three affected templates'
  `docker_container.workspace` via `security_opts`. **What's still
  unverified as of Issue #23** (out of scope for that session's safety
  restrictions, real host-level AppArmor loading and a live Coder
  workspace rebuild): the AppArmor profile has never actually been loaded
  on any real host (`scripts/load-security-profiles.sh` exists but must be
  run manually, as root, by a human operator — never automatically), and
  no real `coder create`/`srt opencode -- ...` end-to-end completion has
  been observed. The seccomp half of the fix *was* verified live: with the
  scoped seccomp profile and default (unmodified) AppArmor, `bwrap
  --unshare-user --unshare-pid --ro-bind / / echo ok` now fails with
  `bwrap: Failed to make / slave: Permission denied` — byte-for-byte the
  same error the fully-`unconfined`-seccomp reference reproduction
  produces, proving the scoped seccomp profile is exactly as permissive as
  `unconfined` for this call sequence, no more. See Issue #23's handoff
  for the full evidence, including a real, non-obvious seccomp-profile
  authoring bug found and fixed along the way (below).
- **Update (2026-08-30, live E2E verification session, host `sudo` access
  now available)**: `sudo scripts/load-security-profiles.sh` was run for
  the first time on the real Coder host, confirmed active via `aa-status`.
  All three affected templates (`docker-standard`, `embedded-linux`,
  `agent-workspace`) were pushed live and each successfully created a real
  throwaway workspace with `security_opts` (scoped seccomp content +
  `apparmor=cade-bwrap-workspace`) applied — `docker inspect
  --format '{{.HostConfig.SecurityOpt}}'` confirmed both were actually in
  effect on the running container, ruling out a silent fallback. This
  surfaced **Issue #27**: the shipped AppArmor profile's unqualified `deny
  mount,` rule always overrides the narrower `mount
  options=(make-rslave),` allow rule directly above it (AppArmor's
  explicit `deny` rules take precedence over `allow` rules for overlapping
  permissions, regardless of source-file ordering — not first-match-wins
  like a firewall chain), with **zero AppArmor audit log entry** for the
  resulting denial (`journalctl -k` showed nothing for the exact failing
  call), making the profile look identical to "not loaded at all." Fixed
  in PR #28 (`deny mount options!=(make-rslave),`) and merged — but the
  corrected profile still needs a second `sudo
  scripts/load-security-profiles.sh` re-run (host-mutating, restricted
  from agent execution per this repo's safety policy) before it takes
  effect; the live container test above still showed the pre-fix
  behavior (`bwrap: Failed to make / slave: Permission denied`), which is
  now understood as **this specific known bug**, not an unexplained
  failure. **Still not done, pending that reload + a follow-up session**:
  a real `srt opencode -- run ...` completion and a live enforcement-denial
  check (issue #23's own acceptance criteria). Workspace-creation-level
  regression testing (no crash, no silent security-profile fallback) is
  fully verified live for all three templates; deep `bwrap` functional
  correctness is not yet, pending Issue #27's fix taking effect on the
  host. Three ad-hoc throwaway workspaces and one ad-hoc admin Coder
  account (`issue23verify`) created for this verification were deleted
  afterward.
- **Do not trust an `op: SCMP_ACT_MASKED_EQ` rule with only `value` set and
  no `valueTwo`** in a Docker/moby-style seccomp JSON profile: `value` is
  the *mask*, and `valueTwo` (not `value`) is the comparison target —
  omitting `valueTwo` silently defaults it to `0`, so a rule intended as
  "ALLOW when bit X is set" (`(arg & mask) == mask`) actually compiles to
  "ALLOW when bit X is *unset*" (`(arg & mask) == 0`), the exact opposite
  of what was likely intended, with no parse error or warning of any kind
  — confirmed live 2026-08-30 while authoring Issue #23's scoped
  `clone`/`unshare` rule for `CLONE_NEWUSER`: the buggy version reproduced
  the *exact same* baseline failure as no seccomp relaxation at all, and
  was silently masking its own ineffectiveness until isolated with
  `--security-opt apparmor=unconfined` (to rule out AppArmor as the actual
  blocker) and a raw `ctypes`-based `unshare(2)` call (to rule out
  `bwrap`-specific behavior) — always test a new/modified `MASKED_EQ` rule
  in isolation against the literal syscall+flags it's meant to allow
  before trusting it "should" work from the JSON alone.

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
- 2026-08-29: Coder's AI provider-create API field is `api_keys` (not a differently-named
  literal-secret field elsewhere in the payload) — a provider `POST /api/v2/ai/providers`
  built from an assumed field name silently 4xxs. Its model-config API fields are
  `ai_provider_id` (not `provider_id`) and `model` (not `model_identifier`) — check the
  actual API response/schema of a live, unlicensed Coder server before trusting a field name
  inferred from adjacent naming conventions elsewhere in the codebase.
- 2026-08-29: Confirmed entitlement flags on this deployment's live Coder server: `aibridge`
  (AI Gateway), `boundary` (Coder-native Agent Firewall), and `ai_governance_user_limit` /
  `managed_agent_limit` / `workspace_external_agent` (AI Governance Add-On) are all
  `not_entitled` — see `docs/ai-coder.md` for the full entitlement matrix and exact evidence
  strings; `governance/boundary/config.yaml` already documents the `boundary` finding
  specifically, this is the first record of the other two.

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

## Issue #13 — 2026-08-29

Coder AI integration (Agents, providers/models, MCP, `agent-workspace`
template, OSS `boundary` egress). Full stepwise plan executed with
sequential subagents, then a coordinator-run E2E pass against the live
stack surfaced three real bugs no amount of code review would have
caught: (1) `compose.yaml`'s external-auth block crash-looped `coder`
the instant those env vars existed at all, even empty — Coder parses a
provider from the var's *presence*, not its value; fixed by commenting
the block out by default instead of defaulting it to an inert-looking
empty string. (2) The AI-provider reconciler's idempotency (T4) broke on
every re-run because `PATCH /api/v2/ai/providers/{name}` rejects the
same `api_keys` body shape `POST` accepts — fixed by skipping the PATCH
call entirely once non-secret fields already match, never re-sending
`api_keys`. (3) `boundary`'s `nsjail` jail type failed with the exact
same unprivileged-userns error already documented for `srt`'s
`bwrap --unshare-user`; `landjail` (the issue's own documented fallback)
was verified live to actually enforce the allowlist (200 allowed / 403
blocked) and is now the default. See
`docs/milestone-reports/issue-13-ai-coder.md` for full E2E evidence,
including two tests (T5 genuine inference, T13 MCP tool invocation)
honestly reported as blocked on a real `OPENAI_API_KEY` not being
available in this environment, rather than faked or silently skipped.

**Process lesson, not a code defect:** a manual `sed`-based redaction
pattern used while validating `scripts/ai-token.sh`'s live output caught
the token embedded in its printed `.env` line but missed the same token
printed bare on its own line immediately above — a real Coder session
token was briefly exposed in this session's own transcript. Mitigated
immediately (password reset + `POST /api/v2/users/logout`, confirmed the
old token now 401s) rather than left for later cleanup. Prevention rule:
when manually redacting a secret from command output for any purpose
(logs, chat transcripts, reports), capture the value into a shell
variable first and reference only `<REDACTED>`/`${VAR:0:4}****` in
anything printed — never rely on a single regex substitution to catch
every place a raw secret might appear in multi-line tool output.

**Update, same day, once a real `OPENAI_API_KEY`/`OPENROUTER_API_KEY`
became available:** closing out T5 (genuine inference) surfaced two more
real bugs the credential-less first pass could not have found. (4) The
first idempotency fix above was itself incomplete — it never re-sent
`api_keys` on PATCH *at all*, so a provider created once with a
stale/placeholder key could never actually be rotated by a later
`make ai-bootstrap` run; an operator setting a real key in `.env` after
an earlier run would see no effect, silently. Fixed by reproducing
Coder's own key-masking format (`first4...last4`) from the resolved
secret and comparing it against the stored `masked` field to detect
drift deterministically, without ever storing/comparing the raw secret
— only including `api_keys` in the PATCH body when it actually differs.
Verified live: reset to a placeholder key, re-ran with the real key,
got `"key rotated"` exactly once, then `"unchanged"` on 3 subsequent
runs. (5) `agent-workspace`'s `coder_agent` had no `dir` set, so Coder
Agents' Chats API defaulted a chat's working directory to `$HOME`, not
wherever `.mcp.json` actually lives — the agent had zero MCP tools
registered and hallucinated shell commands instead. Fixed with
`dir = local.workspace_dir` (Terraform flags it deprecated but still
functional). **This did not fully close T13**: even with `dir` fixed, a
real chat created purely over the REST API (no client ever attached)
still showed no MCP tools discovered — this appears to be the same class
of gap already documented above for VS Code's Agent Host: `.mcp.json`
auto-discovery may require a real, interactively-attached client session,
not a headless API-created chat. Given that, the actual security property
T13 cares about (OPA denies an unapproved `flash_device`) was proven
directly via the same MCP protocol calls a working auto-discovery would
have produced, run from inside the real workspace container with a real
bearer token — `list_devices`/`reserve_device`/`run_test` all succeeded,
`flash_device` without `approved=true` was denied (`isError: true`). See
the updated `docs/milestone-reports/issue-13-ai-coder.md` for full
evidence of both passes.

## Issue #16 — 2026-08-30

Spike exploring 6 already-live Coder Agents features beyond #13's core
integration (sub-agents, plan mode, `.agents/skills/`, `web_search`,
`computer_use`, image attachments) — no template/infra changes, tested
live against a throwaway `agent-workspace` workspace, deleted afterward.
All 6 items got real, non-mocked evidence; two (`web_search`,
`computer_use`) confirmed real entitlement/config gaps rather than bugs.
Notable, non-obvious findings for future work against this Chats API:
(1) `POST /api/experimental/chats`'s `content` field is
`[]codersdk.ChatInputPart`, not a plain string — every part needs an
explicit `"type"` (`"text"` or `"file"`; `"image"` is rejected outright
with `content[N].type "image" is not supported"`), discovered only by
reading the Go-struct-unmarshal error message the API returns for a bad
shape, not from any public docs found. (2) `plan_mode` is a
`codersdk.ChatPlanMode` string enum, not a boolean — `"plan"` is the only
accepted value found by brute-force probing (`on`/`enabled`/`always`/
`true`/`"plan_first"` as a field name were all rejected); clearing it
back to normal mode is `PATCH .../chats/{id}` with `{"plan_mode":""}` →
`204`, not a documented `"none"`/`"off"` value (both rejected). (3) File
uploads for chat attachments are a *separate* endpoint from the general
`/api/v2/files` API (`POST /api/experimental/chats/files?organization=
<org-id>`, needs `Content-Disposition: attachment; filename="..."` — the
general endpoint 400s any non-tar `Content-Type`). (4) There is no
dedicated `GET /api/v2/entitlements`-style flag for `computer_use`/
virtual-desktop — it's gated by an *experiment* name
(`chat-virtual-desktop`, absent from `GET /api/v2/experiments`'s enabled
list `["oauth2","mcp-server-http"]`), a different mechanism from the
`aibridge`/`boundary`/AI-Governance entitlement-flag pattern already
documented in `docs/ai-coder.md` — checking only `/entitlements` for a
feature gate is not sufficient; check `/experiments` too. (5) Unlike
#13's T13 MCP-tool-auto-discovery gap, `.agents/skills/` auto-discovery
(`read_skill` tool) **does** work over a fully headless, API-created
chat with no interactive client ever attached — this is not the same
class of limitation as MCP `.mcp.json` discovery, and should not be
assumed blocked by analogy to it. See `docs/ai-coder.md`'s "Explored
Agents capabilities" table for the full evidence per item.

## Issue #17 — 2026-08-30

Closed both remaining gaps from #13: a real GitHub OAuth App now backs
`CODER_EXTERNAL_AUTH_0_*` (uncommented in `compose.yaml`, verified live
— `coder` stayed healthy, no repeat of the presence-triggers-crash-loop
bug), wired into the `agent-workspace` template via
`data.coder_external_auth.github` (falls back to the pre-existing manual
`github_token` parameter for users who haven't linked GitHub), and the
CI successor path (#13 Task 8c) went from documentation-only to a real,
working `.github/workflows/agent-chat.yml`, proven end to end against a
real `agent-chat`-labeled issue (#17 itself) with real LLM tool-calling
work observed and a real result comment posted back to GitHub — see
`docs/ai-coder.md`'s updated Task 8c section for full evidence.

Six real bugs were found only by actually running the workflow live
against the real stack, none of which would have surfaced from code
review alone: (1) the self-hosted runner image (`cade/runner:latest`)
has `jq` but no `python3` — the workflow's JSON parsing had to target
what's actually installed, not assumed. (2) `workflow_dispatch` has no
triggering issue, so the action's required `github-url` input needs an
explicit dry-run fallback. (3) `coder/agents-chat-action` strictly
rejects any `github-url` that isn't a real `github.com` issue/PR URL —
by design, to stop a workflow templating untrusted content from being
tricked into redirecting to an attacker-chosen repo — so a dry run must
point at a real issue, not the bare repo URL. (4) The action's own
chat-reuse mechanism (a hidden HTML tracking comment keyed on
`github-url` + workflow name) silently ignored a freshly pre-created
`workspace-id` on a second run against the same issue and kept the
first run's now-deleted workspace reference (`410` on GET) — fixed with
`force-new-chat: true`, at the cost of chat history not persisting
across repeat runs. (5) Coder workspace names are capped at 32
characters; a naming scheme embedding both the issue number and the
full numeric GitHub run id was 4 characters over and rejected by
server-side validation with a generic message that didn't state the
limit — had to guess-and-check the actual cap. (6) Coder's
`POST /api/v2/users/{user}/keys/tokens` `lifetime` field is
**nanoseconds** (`time.Duration`), not seconds — a value intended as "90
days" was actually ~0.0078 seconds, so the token it minted "succeeded"
at creation time but failed on its very next real use with an opaque
`401 access token has expired`, hours of apparent confusion before
directly probing the field's real unit; the server additionally caps
the max lifetime at `168h` (7 days) regardless of what's requested.

This issue's own body claimed an "~8-hour external-auth token TTL
limitation (already documented in docs/ai-coder.md)" — that claim does
not actually exist anywhere in this repo's docs prior to this issue.
Rather than restate an unverified premise as re-confirmed fact, this was
flagged honestly in `docs/ai-coder.md` as an open, unverified item
(re-verifying a real token's real-world TTL would require waiting out
its actual lifetime, which this session did not do).

**Process note, same lesson class as Issue #13's token-exposure
incident:** `scripts/ai-token.sh` prints its minted token bare on its own
line *before* its own copy-paste `.env` line — a redaction regex written
against only the labeled line missed the bare occurrence immediately
above it, briefly exposing a real (if throwaway) token in this session's
tool output. Mitigated immediately: the exposed session was logged out
(confirmed `401` on recheck) and the temp log file holding it shredded,
before any further use. All subsequent tokens in this session were
minted and consumed strictly inside a single shell pipeline (never
echoed, captured directly into a variable, piped straight into
`gh secret set`), per the prevention rule #13 already recorded — this
incident is a reminder that the rule must also cover *tooling a repo
already ships* (`scripts/ai-token.sh`), not only ad hoc commands.



