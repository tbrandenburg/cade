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
`docs/phases/` splits it into 5 deliverable phases, each with its own
milestones and required milestone report under `docs/milestone-reports/`.
See the top-level `README.md` for a quickstart and current project status.

Two directories look similar but are not: `docs/` is the human-facing project
plan/documentation (source of truth); `doc/plan/` is this repo's own
internal, plan-driven build-process state (used by `scripts/factory.sh`, the
OpenCode-based orchestrator that has been driving this project's own
implementation step-by-step) — do not confuse the two when looking for
context.

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

_(Actionable, still-relevant lessons only — technical pitfalls and review checklist items. Historical blow-by-blow of who-missed-what has been pruned; see git history of this file if needed.)_

### Review checklist (recurring failure mode: undelivered/uncommitted artifacts)

A step/milestone report claiming completion is not evidence by itself. Before trusting any
milestone report or "done" claim, always:
- Run `git log --all -- <path>` (and `git status --short`) for every file/path the step
  claims to have created or updated — uncommitted working-tree changes do not exist for a
  workspace that clones from the remote, and repeatedly recurred as the single biggest
  cause of false "done" claims across M0/M3/M4/M5/M9.
- Diff a report file against its prior committed version if a step claims to have rewritten
  it — a byte-identical file means it was only re-saved, not actually redone.
- Never trust "Succeeded"/"Started"/"Active" status strings alone. Cross-check with real
  system state: `docker ps`/`docker inspect` for containers, `coder templates versions
  list <name>`/`coder templates pull <name> <dir> --yes` (diffed against repo source) for
  templates, and `docker exec <container> cat /tmp/coder-startup-script.log` (or `ps aux`
  inside the container) for workspace provisioning/E2E claims.
- As the implementer: commit and push every deliverable as the literal first action of a
  step, before writing the milestone report — this is what finally broke the recurring
  cycle in one pass (see M9 step 00601).

### Coder / Terraform / Docker technical notes

- `coder` CLI may not be on `PATH`; check for it under `/tmp/coderbin/bin/coder` or similar
  before concluding it's unavailable. The Coder server itself runs as the `coder` Docker
  container.
- `coder create ... --yes` still prompts interactively for any `coder_parameter` without an
  explicit `--parameter` value (even ones with a `default`) — pass every parameter
  explicitly for non-interactive creates, or it hangs and fails with an opaque
  `prepare build: EOF`.
- `coder --global-config <dir> list` hides other users' workspaces unless given `-a`/
  `--all`; `coder ssh`/`coder show` against another user's workspace fails with a generic
  "Resource not found" (not permission-denied-shaped) — run `coder whoami` first to check
  which account is authenticated before assuming a workspace is unreachable.
- `coder stop --yes` + `coder start --yes` fully destroys/recreates the `docker_container`
  resource while leaving `docker_volume.home_volume` untouched — useful as a non-GUI proxy
  for "end a session, start a new one" when testing persistence across the home volume.
- `coder templates push` only uploads the template's own directory, not the surrounding
  repo — a `docker_image` resource cannot reference a Dockerfile via
  `${path.module}/../../...`. Build/tag the workspace image out-of-band first (e.g. `make
  coder-workspace-build`) and have `docker_container` reference the pre-built tag by name.
- The `coder_agent` template's plain `git clone "${repo_url}"` silently hangs/fails for
  private repos (falls into Coder's external-auth flow, never completes non-interactively).
  Diagnose via `/tmp/coder-startup-script.log` inside the container. Fix: an optional
  `github_token` `coder_parameter` wired into `GIT_ASKPASS` only for the clone step (keeps
  the token out of `.git/config`). Also, `docker exec` into a workspace container does not
  inherit `coder_agent.env` (e.g. `GITHUB_TOKEN`, `GIT_AUTHOR_NAME`) — manual verification
  needs its own `git config user.email/user.name`.
- `ubuntu:24.04` already ships a `ubuntu` group/user at uid/gid 1000 — a plain `groupadd
  --gid 1000 coder` fails; detect and rename the existing group/user instead.
- A `RUN --mount=type=secret,id=cacert` layer that ran once without the secret present gets
  BuildKit-cached as a no-op; rebuilding later *with* the secret silently reuses the stale
  cached layer unless rebuilt with `--no-cache`. Don't trust "no error" as proof a
  secret-dependent step actually ran with the secret.

### Sandbox / security

- Anthropic's Sandbox Runtime (`srt`) wraps commands in `bwrap --unshare-user`, which fails
  outright in this Docker/WSL2 environment (`bwrap: No permissions to create new
  namespace`) because Docker's default seccomp/AppArmor profile blocks unprivileged userns
  creation — not a host `sysctl` issue. Do not fix this by adding `--privileged` or loosening
  the workspace container's seccomp/AppArmor profile in Terraform — that's a security-
  posture decision outside a single step's authority. Document `srt` as installed/configured
  but non-enforcing in this deployment instead.
