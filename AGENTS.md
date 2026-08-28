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

### Coder / Terraform / Docker

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

### Sandbox / security

- `srt`'s `bwrap --unshare-user` fails in this Docker/WSL2 environment (blocked unprivileged
  userns, not a host `sysctl` issue). Do not fix with `--privileged` or loosened
  seccomp/AppArmor in Terraform — document `srt` as installed but non-enforcing instead.
