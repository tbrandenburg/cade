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
- **Workspace-app tiers (`coder/templates/docker-workspace/main.tf`)** —
  any new dashboard app/tile follows one of three tiers; pick the tier
  deliberately, don't invent a fourth mechanism:
  1. **Core, always on, no `coder_parameter`** — e.g. VS Code Web
     (`module.code-server`, gated only by `count =
     data.coder_workspace.me.start_count`) and SSH/Web Terminal (Coder
     platform built-in, not template-defined at all).
  2. **Optional, creation-time `coder_parameter`** (bool, default
     `"false"`, `mutable = true`, gates `count` on the `coder_app`/
     `coder_script` pair) — e.g. `temporal_owned`, `enable_jupyter`,
     `enable_nodered`. A human passes `--parameter <name>=true` at
     `coder create` time to opt in.
  3. **Optional, post-instantiation** — any Tier-2 parameter can be
     flipped on an *existing* workspace, no recreate needed, via the
     generic `scripts/set-workspace-parameter.sh <owner>/<ws>
     <param_name> <value>` (does the stop-then-start-with-all-current-
     parameters dance, working around `coder update`'s
     drops-parameters-on-second-build bug — see the script's header).
     `set-workspace-temporal-tile.sh`/`-jupyter.sh`/`-nodered.sh` are
     already thin wrappers around it — a new app gets Tier 3 for free
     from Tier 2, no new script required. See
     `.agents/skills/coder-app-tile/SKILL.md` for the full Terraform
     shape.
- **Internal (workspace-context) vs. external (platform-service)
  components — what actually runs where, and why** (2026-09-01, captured
  during a design-review chat, not a code change):

  | Component | Where it runs | Internal or External | Why |
  |---|---|---|---|
  | Temporal server (frontend/history/matching/UI) | `temporal` container, always-on | External | Shared, multi-tenant service — one cluster/UI serves every workspace's workflow history simultaneously; not scoped to a single workspace by design. |
  | Temporal worker (`temporal-worker`) | Separate container, always-on | External | Polls the shared task queue and reaches *into* workspaces only via `docker exec` (through `runner-docker-proxy`/`build-docker-proxy`). No hard technical wall forces it inside a workspace — `docker exec` already gives full external reach, unlike omnigent's case below. See Issue #88 (groomed, not started) for the "should it ever move in-workspace" question. |
  | Temporal `coder_app` tile | Points at the external Temporal UI | External (`external = true`) | Deep-linked with `?query=WorkflowId STARTS_WITH ...` to filter to a workspace's own workflows — gives a per-workspace *view* without needing a per-workspace *instance*. |
  | omnigent-server + omnigent-db | Separate containers, always-on | External | Shared accounts/host-registry/orchestration backend across all workspaces — same multi-tenant reasoning as Temporal's server. |
  | omnigent host daemon (`omnigent host --background`) | Started by the workspace's own `coder_agent.startup_script`, runs inside the workspace container | **Internal** | Genuinely workspace-scoped: same container, same user, same `docker_volume.home_volume` (identity persisted to `~/.omnigent/config.yaml`, survives `coder stop`/`start`). |
  | Sandboxed `opencode serve` (`srt`-wrapped) | Inside the workspace container, private network namespace | **Internal** | The actual agentic session; has to live in-workspace since it's the thing being sandboxed. |
  | Reverse Unix-socket bridge (Issue #45) | Inside the workspace container | **Internal, and structurally forced to be** | `srt`'s `bwrap --unshare-net` makes the sandboxed process's TCP port unreachable from any external caller — a Unix socket (crosses netns via a shared bind-mount) was the only way to connect the externally-reaching daemon to the isolated sandbox. This is the one genuine hard wall in the whole comparison. |
  | omnigent `coder_app` tile | Points at the external omnigent-server dashboard | External (`external = true`) | Same reasoning as Temporal's tile — the web UI is the shared, multi-tenant surface; only the daemon+bridge behind it is workspace-local. |
  | JupyterLab / Node-RED / code-server (`external = false` reference pattern) | Started via `coder_script`/`startup_script`, tied to `coder_agent.id`, `url = localhost:PORT` | **Internal** | Structurally enforced by Terraform: `agent_id` ties the app to one specific workspace's agent, and Coder's proxy tunnel can only reach that container's own network namespace — no code path lets it be anything else. |

  **Net pattern**: something is only forced *internal* when there's a real
  technical wall preventing external reach (namespace isolation,
  per-workspace filesystem/volume dependency) or when Terraform's
  `agent_id` binding structurally requires it (the `external = false`
  reference pattern above). Everything else — shared, multi-tenant,
  product-level UIs/servers (Temporal, omnigent-server) — stays *external*
  by design: embedding them would either be meaningless (same shared UI
  duplicated per workspace) or require a brand-new scoping/proxy component
  that doesn't exist and isn't currently justified. A registered
  `coder_app` tile existing at all is **not** evidence its target actually
  works correctly through Coder's real proxy in a live browser — see
  `.agents/skills/coder-app-tile/SKILL.md`'s "Validation before calling an
  integration done" checklist; only a live pass through the real dashboard
  proxy is real evidence, never `terraform validate`/a direct container
  curl alone.

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
| `make coder-workspace-build` | M3 | Builds and tags the `cade/coder-workspace:latest` image that Coder workspaces run (`docker-workspace` template). **Refuses to run if `examples/`, `coder/`, or `Makefile` have uncommitted changes** (the Terraform template clones the *remote* repo, so building from a dirty tree would produce an image that doesn't match what a real workspace clones) — commit and push first. Pass `CACERT=/path/to/ca-bundle.pem` if operating behind a corporate TLS-intercepting proxy; omit it on unrestricted networks. |
| `make embedded-workspace-build` | M6 | Same dirty-tree refusal rule, but builds `cade/embedded-linux-workspace:latest` (cmake/ninja/gcc-aarch64-cross/qemu-user) for the `embedded-linux` template. |
| `make agent-workspace-build` | Issue #13 | Depends on `coder-workspace-build` (inherits its dirty-tree refusal guard); builds `cade/agent-workspace:latest` (adds the OSS `boundary` network-isolation CLI) for the `agent-workspace` template, used for long-running Coder Agents sessions. |
| `make templates-push` | — | Pushes `docker-workspace`, `embedded-linux`, `devcontainer`, and `agent-workspace` templates to the running Coder server in one shot (`coder templates push ... --yes` x4). Depends on all four `*-workspace-build` targets — also (re)builds the images first (cache-hit, near-instant unless code changed) and inherits their dirty-tree refusal check. Requires the `coder` CLI on `PATH`, an authenticated session, and Coder already up/healthy. |
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
| `make coder-svc-token` | Issue #50 | Mints a narrowly-scoped Coder API token for the dedicated `temporal-svc` user (`scripts/coder-svc-token.sh`) — used for Temporal-owned persistent workspace lifecycle (create/operate, not admin). |
| `make temporal-workspace-demo-start` | Issue #50 | Starts one execution of `PersistentWorkspaceBuildWorkflow` against a demo `tw-demo` workspace, resolved-or-created entirely through the Coder API. |
| `make temporal-reaper-schedule` | Issue #50 | Creates/updates the 15-minute Temporal Schedule that runs `WorkspaceReaperWorkflow` (idempotent — safe to re-run from `make up`). |

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

_(Recurring, transferable pitfalls only — imperative prevention rules. Chronology, issue numbers, and one-off observations pruned; see git history for full narrative detail if needed.)_

### Evidence & "done" claims

- Never trust a subagent's "complete"/"passing" report — check `git log --oneline -3 <branch>` (not just `git status`) to confirm it actually committed.
- Treat any change to `compose.yaml`/a template/a config file as inert until the consuming container is verified recreated (`docker inspect ... Config.Env`) — a committed diff and a live effect are different claims.
- Never trust a `200`/"Succeeded" status string alone — cross-check the real resource (`docker inspect`, `docker exec ... cat log`, a live API round trip) before declaring a step done.
- Run `git status --short` on the *whole* repo, not just the files you think you touched, before closing any step — untracked deliverables (reports, screenshots, doc edits) are the most common false "done".
- `git add` silently no-ops on gitignored paths (e.g. screenshots under `.playwright-mcp/`) — use `git add -f` for any deliverable saved under a gitignored dir.
- Re-verify a stated blocker's premise with one direct command (e.g. `gh repo view --json visibility`) before repeating a prior remediation plan — the premise may no longer hold.
- A merged upstream PR fixing a dependency is not a released fix — verify the *published registry metadata for the exact pinned version*, not the source repo's default branch.

### Live-vs-synthetic verification

- Never trust a direct-container/synthetic reproduction (`docker exec ... curl`, a bare `bwrap` smoke test, an isolated unit repro) as proof a fix works — always re-verify through the real caller (the actual dashboard proxy, the real CLI invocation, the real multi-hop flow) before closing an issue.
- An "official upstream approach should just work" claim is a hypothesis, not evidence — verify against this specific deployment/version through the real proxy/API before trusting it.
- A `200` response with an empty/wrong body is not success — always check response length/content, not just status code, especially through a real reverse proxy.
- Manually diff a subagent's changes line-by-line against the target branch before merging, especially near a resource with a previously-hardcoded identifier — `terraform validate`/`fmt` passing does not prove an adjacent critical line wasn't silently dropped.
- Fixing one bug (a CLI flag, a syntax error) can fully mask a second, independent bug behind it — after any fix, re-verify the *whole* call path (auth, execution, effect), not just that it now parses.
- Before assuming a third-party CLI/library flag exists, run `--help`/read the installed source for the *actual installed version* — don't infer flag names from naming conventions used elsewhere in the repo.
- Before trusting a new third-party dependency import, actually run it inside the real built artifact — a sibling service using it is not proof it's declared as a dependency here.
- Env vars documented as "the mechanism" by one code path can be silently dropped by a different layer (e.g. a security allowlist) — trace any env var all the way from where it's set to where it's actually consumed, in a live process.

### Coder / Terraform / Docker

- `coder templates push` never resets an already-pushed variable to its `.tf` default — only an explicit `--variable` overrides the live value; re-run a drift-check script after any `.tf` default change.
- Pass every `coder_parameter` explicitly on `coder create --yes`, even ones with defaults — otherwise it hangs with an opaque `prepare build: EOF`.
- `coder stop`/`start` recreates the container but does not pick up a newer template version, and does not disturb `docker_volume.home_volume` — use `coder update` (or a fresh `create`) to actually test a new template version.
- A `docker_volume` with `lifecycle { ignore_changes = all }` is still destroyed by `coder delete` — for a volume meant to survive delete/recreate, reference it by a fixed name in the container only, never declare it as its own resource.
- Coder's path-based `coder_app` proxy strips the app's URL prefix and sends no `X-Forwarded-Prefix` — never assume a proxied backend's base-path config "should" match Coder's request path without a live dashboard-proxy curl test first.
- A `coder_app.icon`/asset over plain HTTP is silently blocked by the default CSP with no server-side error — always visually re-verify any icon/CSP change in a real browser console.
- Before creating a bind-mounted secret/data volume, verify group/uid ownership and permission bits (openbao, docker-socket-proxy) explicitly — default container UIDs/GIDs are not guaranteed to match host expectations.
- A `docker-socket-proxy`/similar allowlist denial (`BUILD=0`, `EXEC=0`) looks like a generic `403`, not an auth error — widen only the single capability actually needed, and prove it via a before/after test, not assumption.
- `docker compose up`/a container recreate does not survive a stale `.env` value (e.g. `DOCKER_GID`) silently drifting from the real host state — re-verify host facts (`getent group docker`) whenever a recreate fails with a permission error.
- Pin an explicit top-level `name:` in `compose.yaml` before any project-directory rename — otherwise Compose derives volume/project names from the directory name and a rename silently orphans all persistent data.

### Sandbox / security

- Docker layers multiple independent confinement mechanisms (seccomp, AppArmor, capabilities, `systempaths`) — when a sandboxing fix "should" work but doesn't, toggle each layer to its most permissive setting individually to isolate which one is still blocking, rather than assuming the last-touched layer is at fault.
- Disabling one confinement mechanism is only safe if another mechanism already independently enforces the same boundary — verify this explicitly, never assume any `unconfined`-named flag is inherently safe.
- A stale, already-pushed template silently embeds old security-profile *content* — always re-push and recreate the workspace before re-testing a profile change, or a fixed bug can look unfixed.
- In seccomp JSON, a `SCMP_ACT_MASKED_EQ` rule with `value` (mask) but no `valueTwo` (target) silently defaults to comparing against 0 — the opposite of the intended rule, with no parse error. Always test a new/modified rule in isolation against the exact syscall+flags it's meant to allow.
- In AppArmor, an unqualified `deny` rule always overrides a narrower `allow` rule for the same permission regardless of file order, often with zero audit-log entry — write `deny` rules with explicit `!=` exceptions, and check `journalctl -k` for silence, not just presence, when debugging.
- A network-namespace-isolating sandbox (`bwrap --unshare-net`) makes a sandboxed process's listening port unreachable from an external, unsandboxed caller — a Unix-domain socket (crossing via a shared bind-mount) is a viable bridge; a dead socket file is not auto-removed, so liveness must be actively probed, not inferred from file existence.
- A `pgrep -f '<script-name>'` self-check inside a script invoked as `sh -c "<script text>"` can match its own already-running process (the full script text is the command line) — use a PID file instead.
- A PATH-shadowing shim's own directory left on PATH can cause a tool it invokes to recurse back into the shim itself — always pass an absolute path to anything a shim launches, never a bare command name.

### Environment / process

- Fully detach any backgrounded long-lived process in a persistent shell-tool session (`setsid ... </dev/null >file 2>&1 & disown`) — otherwise it holds the tool's stdout pipe open and every later command in that session appears to hang.
- An apparent hang on a chained shell command is not proof of a functional bug — re-run each step individually with a bounded timeout, and check the real service's own logs, before concluding anything is stuck.
- docker-outside-of-docker (bind-mounting the host socket) resolves bind-mount paths against the *real host filesystem*, not the calling container's view — it silently fails when the calling container's own workspace is a named volume rather than a real host path; check official reference templates for a supported alternative (e.g. nested DinD) before hand-rolling this.
- Merge a finished subagent's branch into a fresh coordinator-owned integration branch, never directly onto a local `main` that tracks `origin/main` — absence of GitHub branch protection does not make a direct merge safe.
- When delegating any task that plausibly touches host-level state, state the safety boundary (no `sudo`, no `--privileged`, no touching running containers) explicitly in the subagent prompt up front, rather than discovering it via a rejected permission prompt.
- Never rely on a single regex substitution to redact a secret from multi-line command/tool output — capture it into a variable first and reference only a redacted placeholder in anything printed.

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



