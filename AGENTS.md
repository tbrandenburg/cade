# AGENTS.md — cade

Instructions and accumulated knowledge for any AI agent (human or automated) working in this repository. Update this file at the end of every phase per `docs/phases/README.md`.

## How to use this file

- Read this file before starting work on any phase or milestone.
- Read `docs/ARCHITECTURE.md` alongside it — a condensed C4-model view of the platform; `docs/INITIAL.md` remains authoritative for details.
- Update it before closing out a phase — do not leave it stale.
- **Keep this file ≤250 lines.** AGENTS.md is agent operating guidance only — not a changelog, postmortem, or design-review transcript. Never add a dated, issue-by-issue narrative section; extract only the durable, transferable rule (≤2 lines/40 words) into "Guidelines" or "Lessons Learned". Full narrative history belongs in `docs/milestone-reports/`.
- Prefer appending to "Lessons Learned" over rewriting history; only edit "Guidelines" when a rule changes. If a new entry pushes the file over budget, compress an existing one first.

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

_(Concrete, binding rules discovered during implementation — not restated theory from `docs/INITIAL.md`. Keep each bullet to 2-3 lines; put narrative justification in a milestone report, not here.)_

- **Startup ordering** — `docker compose up -d` has no explicit cross-service health gate; `coder`/`temporal`/`openbao` take 10-60s to become healthy after their DB dependency is up. Run `make status` and wait for all `(healthy)`/`Up` before any workspace/Temporal/MCP call.
- **Cross-network dependency** — the Temporal ↔ lab-sim capability call needs `temporal-worker` on the `platform-workspaces` network; verify with `docker inspect temporal-worker --format '{{json .NetworkSettings.Networks}}'` if an Activity can't reach `lab-sim`.
- **Backup/restore** — see `docs/disaster-recovery.md` for the full procedure; never back up OpenBao's unseal key shares in the same artifact/location as the storage directory they unseal.
- **Durability Test 3 is per-workspace-type** — proving it on one Coder template does not prove it on another; each declares its own `docker_volume.home_volume`. Verify the specific template a release claims to support.
- **Workspace-app tiers** (`coder/templates/docker-workspace/main.tf`) — a new dashboard app follows one of three tiers: (1) core/always-on, no parameter; (2) optional creation-time `coder_parameter`; (3) optional post-instantiation via `scripts/set-workspace-parameter.sh`. Pick deliberately; see `.agents/skills/coder-app-tile/SKILL.md` for the Terraform shape.
- **Internal vs. external components** — a component is only forced internal by a real technical wall (namespace isolation, per-workspace volume dependency) or Terraform's `agent_id` binding; shared, multi-tenant services (Temporal, omnigent-server) stay external by design. A registered `coder_app` tile existing is not evidence it works — only a live pass through the real dashboard proxy counts, never `terraform validate` alone.

## Agent Instructions

### How to use the Makefile

All platform lifecycle operations are exposed as `make` targets at the repo
root (see `Makefile`); run them from the repo root, not from subdirectories:

| Command | Milestone | What it does |
|---|---|---|
| `make doctor` | M0 | Verifies the host (OS, arch, tooling, disk space, outbound connectivity, port availability) meets baseline requirements before anything else is attempted. Run this first on any new host. |
| `make up` | M1 | Starts the platform control plane (Postgres + Coder) via `docker compose up -d`. Requires `.env` (copy from `.env.example` first). Depends on `temporal-worker-build`/`lab-sim-build` — those two services reference local-only images with no `build:` stanza in `compose.yaml`, so `up` builds them first (cache-hit, near-instant, unless code changed). Prints the main web UI URLs (Coder, Temporal, Grafana) afterward. |
| `make down` | — | Stops and removes the platform stack's containers. Does not touch named volumes (`coder_db_data`, `coder_home`, etc.) — data persists across `down`/`up`. |
| `make status` | — | `docker compose ps` — check container health before assuming the stack is up. Covers all 18 services (Coder, Temporal, OpenBao, OPA, MCP lab-sim, Prometheus/Loki/Grafana, self-hosted-runner support, registry, cAdvisor). |
| `make logs` | — | `docker compose logs -f` — tail logs when diagnosing a stack issue. |
| `make coder-workspace-build` | M3 | Builds and tags the `cade/coder-workspace:latest` image that Coder workspaces run (`docker-workspace` template). **Refuses to run if `examples/`, `coder/`, or `Makefile` have uncommitted changes** (the Terraform template clones the *remote* repo) — commit and push first. Pass `CACERT=/path/to/ca-bundle.pem` behind a TLS-intercepting proxy. |
| `make embedded-workspace-build` | M6 | Same dirty-tree refusal rule, but builds `cade/embedded-linux-workspace:latest` (cmake/ninja/gcc-aarch64-cross/qemu-user) for the `embedded-linux` template. |
| `make agent-workspace-build` | Issue #13 | Depends on `coder-workspace-build` (inherits its dirty-tree refusal guard); builds `cade/agent-workspace:latest` (adds the OSS `boundary` network-isolation CLI) for the `agent-workspace` template, used for long-running Coder Agents sessions. |
| `make templates-push` | — | Pushes `docker-workspace`, `embedded-linux`, `devcontainer`, and `agent-workspace` templates to the running Coder server in one shot. Depends on all four `*-workspace-build` targets and inherits their dirty-tree refusal check. Requires the `coder` CLI on `PATH`, an authenticated session, and Coder already up/healthy. |
| `make runner-build` / `make runner-run` | M2 | Builds the self-hosted GitHub Actions runner image; prefer `bash scripts/runner-jit-start.sh` directly for a real JIT (one-job-then-destroy) registration. |
| `make temporal-worker-build` | M8 | Builds `cade/temporal-worker:latest`. |
| `make lab-sim-build` | M11 | Builds `cade/lab-sim:latest` (no Terraform template, so no dirty-tree check). |
| `make temporal-demo-start` | M8 | Starts one durable-workflow execution against the live Temporal cluster; prints `workflow_id`. |
| `make governance-bootstrap` | M12 | Init/unseal OpenBao, rotate Phase 1-3 credentials, revoke root token. **Must be re-run any time the `openbao` container is recreated** — it does not auto-unseal across restarts. |
| `make governance-verify` | M12 | Runs `opa test` plus a live OPA/MCP ALLOW-`run_test` / DENY-`flash_device` round trip (`scripts/verify-governance.sh`). |
| `make backup` / `make restore-test` | M14 | Creates a timestamped backup set under `backup/artifacts/<timestamp>/` (git bundle, Coder DB, Temporal DB, OpenBao snapshot + unseal keys, workspace home volumes); `restore-test` destroys and restores them (`scripts/restore-test.sh`, `docs/disaster-recovery.md`). |
| `make ai-bootstrap` / `make ai-token` / `make verify-ai` | Issue #13 | Reconciles `coder/ai/{providers,models}.yaml` into the running Coder deployment; mints an admin token first (`scripts/ai-token.sh`); `verify-ai` proves the integration end to end. |
| `make omnigent-bootstrap` | Issue #43 | Creates the first `omnigent-server` admin account. |
| `make coder-svc-token` | Issue #50 | Mints a narrowly-scoped Coder API token for the dedicated `temporal-svc` user — used for Temporal-owned persistent workspace lifecycle (create/operate, not admin). |
| `make temporal-workspace-demo-start` | Issue #50 | Starts one execution of `PersistentWorkspaceBuildWorkflow` against a demo `tw-demo` workspace, resolved-or-created entirely through the Coder API. |
| `make temporal-reaper-schedule` | Issue #50 | Creates/updates the 15-minute Temporal Schedule that runs `WorkspaceReaperWorkflow` (idempotent — safe to re-run from `make up`). |

`examples/hello-service/Makefile` and `examples/embedded-sim/Makefile` have
their own `build`/`test`/`run`/`clean` targets — toolchain smoke tests
proving a freshly provisioned Coder workspace can build/test/cross-compile
unmodified code.

There is no single "build everything"/"test everything" target — `make
status` (all services healthy) is the closest equivalent; validating an
individual milestone means running its own `scripts/*.sh` directly. Check
`docs/phases/*.md` and `docs/milestone-reports/*.md` for the exact commands
a given milestone expects before claiming it passes.

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
   VS Code (Remote-SSH or `code-server`); where no GUI is available,
   `docker exec` into `coder-<owner>-<name>` is an equivalent proxy.
3. **Seed a regression** — edit `examples/embedded-sim` to break a known
   test (e.g. corrupt the checksum known-answer vector), commit, push.
4. **Observe CI fail** — `gh run list --workflow=embedded-build.yml
   --limit 1`; service with the self-hosted runner if needed
   (`bash scripts/runner-jit-start.sh`).
5. **Agent investigation** — `investigate-failure.lock.yml` fires on the
   failed `workflow_run`; verify it reaches a real conclusion (see
   `docs/security.md` M10/M15 for a known docker-socket-proxy limitation).
6. **Local capability + durable orchestration** — trigger the deterministic
   Temporal workflow (`python -m demo.e2e_starter --device-id <id>
   --wait`) and confirm the job lands on the self-hosted runner.
7. **Durability Test 2 (Temporal)** — while a workflow is running, `docker
   compose restart temporal-worker`; the workflow must still complete.
8. **Durability Test 1 (AHP)** — with an agent session active, close and
   reopen VS Code (or reattach); the same session must continue.
9. **Durability Test 3 (Coder)** — write a marker file with a unique,
   timestamped value into `/home/coder`, `coder stop <owner>/<name>
   --yes`, then `coder start <owner>/<name> --yes`; assert the file
   survives byte-for-byte — confirms the volume name is pinned, not
   recreated.
10. **Governance** — attempt a prohibited `lab-sim` operation (e.g.
    `flash_device` without `approved=true`); OPA must deny it
    (`scripts/verify-governance.sh`).
11. **Observability** — find the run's metrics/logs in Grafana correlated
    by timestamp, per `docs/operations.md`.
12. **GitHub result** — confirm the final result is posted back to GitHub.
13. **Backup/restore** — `make backup` then `make restore-test`; verify
    per the checklist in `docs/disaster-recovery.md`.
14. Delete any test workspaces/branches created for this run once every
    check above has passed.

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
- An operational runbook (e.g. disaster-recovery) must live in the persistent ops doc a future incident responder would actually reach for — a milestone report alone doesn't count as "documented".

### Live-vs-synthetic verification

- Never trust a direct-container/synthetic reproduction (`docker exec ... curl`, a bare `bwrap` smoke test, an isolated unit repro) as proof a fix works — always re-verify through the real caller (the actual dashboard proxy, the real CLI invocation, the real multi-hop flow) before closing an issue.
- An "official upstream approach should just work" claim is a hypothesis, not evidence — verify against this specific deployment/version through the real proxy/API before trusting it.
- A `200` response with an empty/wrong body is not success — always check response length/content, not just status code, especially through a real reverse proxy.
- Manually diff a subagent's changes line-by-line against the target branch before merging, especially near a resource with a previously-hardcoded identifier — `terraform validate`/`fmt` passing does not prove an adjacent critical line wasn't silently dropped.
- Fixing one bug (a CLI flag, a syntax error) can fully mask a second, independent bug behind it — after any fix, re-verify the *whole* call path (auth, execution, effect), not just that it now parses.
- Before assuming a third-party CLI/library flag exists, run `--help`/read the installed source for the *actual installed version* — don't infer flag names from naming conventions used elsewhere in the repo.
- Before trusting a new third-party dependency import, actually run it inside the real built artifact — a sibling service using it is not proof it's declared as a dependency here.
- Env vars documented as "the mechanism" by one code path can be silently dropped by a different layer (e.g. a security allowlist) — trace any env var all the way from where it's set to where it's actually consumed, in a live process.
- A sandbox/jail-type option can fail with the exact same error as an unrelated known bug — verify the specific fallback with a live allow/deny round trip, don't assume an alternative works just from its name.

### Coder / Terraform / Docker

- A `server create-admin-user`-bootstrapped admin can never delete or suspend itself via `coder users delete/suspend` — mint throwaway test admins sparingly and clean them up from a *different* already-authenticated session, or accept they accumulate.
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
- Coder parses an external-auth/AI provider from an env var's *presence*, not its value — comment out an unused integration block entirely, never default it to an inert-looking empty string.
- A masked-secret PATCH endpoint may reject the same body shape its POST accepts — only resend a secret once you've reproduced the provider's own masked format and detected real drift.
- A freshly-created, never-logged-in Coder user's workspace agent returns `401 dormant`, not the suspend-rejection error — always `coder users activate` first so a later `suspend`-rejection regression test isn't masked by the dormant-user 401.
- Coder Agents' Chats API needs `coder_agent.dir` set or MCP tool auto-discovery silently fails (defaults to `$HOME`); `.agents/skills/` discovery works headless, `.mcp.json` discovery may not — don't assume by analogy.
- A REST API field can be a string enum, not a boolean, with a non-obvious "reset" value — probe the actual accepted values directly rather than guessing from convention; also check `/api/v2/experiments`, not just `/entitlements`, for feature gates.
- Coder's token `lifetime` field is nanoseconds, not seconds, and is capped server-side (168h) regardless of what's requested — verify the created token's actual `expires_at`, not just a non-error create response.
- A chat/action's run-reuse mechanism can silently ignore a freshly pre-created resource id on repeat runs — set an explicit `force-new` flag rather than assuming reuse detection works.
- Coder workspace names are capped at 32 characters with a generic validation error that doesn't state the limit — keep generated names short and check the actual count.
- A nested devcontainer's own `--add-host=...:host-gateway` resolves to *its* bridge gateway, not the outer Coder server — pin the outer container's real `host.docker.internal` IP as a literal `--add-host` runArg instead of relying on the magic value.
- `gh repo view --json <field>` field names don't always match the CLI docs' apparent shorthand (e.g. `parent` is `{name, owner:{login}}`, never a flat `nameWithOwner`) — pipe one real response through `jq` to confirm the actual shape before writing an extraction filter.

### Sandbox / security

- Docker layers multiple independent confinement mechanisms (seccomp, AppArmor, capabilities, `systempaths`) — when a sandboxing fix "should" work but doesn't, toggle each layer to its most permissive setting individually to isolate which one is still blocking, rather than assuming the last-touched layer is at fault.
- Disabling one confinement mechanism is only safe if another mechanism already independently enforces the same boundary — verify this explicitly, never assume any `unconfined`-named flag is inherently safe.
- A stale, already-pushed template silently embeds old security-profile *content* — always re-push and recreate the workspace before re-testing a profile change, or a fixed bug can look unfixed.
- In seccomp JSON, a `SCMP_ACT_MASKED_EQ` rule with `value` (mask) but no `valueTwo` (target) silently defaults to comparing against 0 — the opposite of the intended rule, with no parse error. Always test a new/modified rule in isolation against the exact syscall+flags it's meant to allow.
- In AppArmor, an unqualified `deny` rule always overrides a narrower `allow` rule for the same permission regardless of file order, often with zero audit-log entry — write `deny` rules with explicit `!=` exceptions, and check `journalctl -k` for silence, not just presence, when debugging.
- A network-namespace-isolating sandbox (`bwrap --unshare-net`) makes a sandboxed process's listening port unreachable from an external, unsandboxed caller — a Unix-domain socket (crossing via a shared bind-mount) is a viable bridge; a dead socket file is not auto-removed, so liveness must be actively probed, not inferred from file existence.
- A `pgrep -f '<script-name>'` self-check inside a script invoked as `sh -c "<script text>"` can match its own already-running process (the full script text is the command line) — use a PID file instead.
- A PATH-shadowing shim's own directory left on PATH can cause a tool it invokes to recurse back into the shim itself — always pass an absolute path to anything a shim launches, never a bare command name.
- `srt`/`@anthropic-ai/sandbox-runtime` hardcodes `.claude/commands`/`.claude/agents` as mandatory-deny-write (project-wide, not just `$HOME`), independent of `srt-settings.json`'s `denyRead`/`allowWrite` — no granular escape hatch exists short of `filesystem.disabled` (drops all FS protection); see `docs/security.md` Issue #118.

### Environment / process

- Fully detach any backgrounded long-lived process in a persistent shell-tool session (`setsid ... </dev/null >file 2>&1 & disown`) — otherwise it holds the tool's stdout pipe open and every later command in that session appears to hang.
- An apparent hang on a chained shell command is not proof of a functional bug — re-run each step individually with a bounded timeout, and check the real service's own logs, before concluding anything is stuck.
- docker-outside-of-docker (bind-mounting the host socket) resolves bind-mount paths against the *real host filesystem*, not the calling container's view — it silently fails when the calling container's own workspace is a named volume rather than a real host path; check official reference templates for a supported alternative (e.g. nested DinD) before hand-rolling this.
- Merge a finished subagent's branch into a fresh coordinator-owned integration branch, never directly onto a local `main` that tracks `origin/main` — absence of GitHub branch protection does not make a direct merge safe.
- When delegating any task that plausibly touches host-level state, state the safety boundary (no `sudo`, no `--privileged`, no touching running containers) explicitly in the subagent prompt up front, rather than discovering it via a rejected permission prompt.
- A live E2E claim against a running Coder stack needs the `coder` CLI installed at a version matching the server (`coder version` mismatch breaks commands); install user-locally (`--prefix ~/.local`), never system-wide, without explicit permission.
- Never rely on a single regex substitution to redact a secret from multi-line command/tool output — capture it into a variable first and reference only a redacted placeholder in anything printed.
