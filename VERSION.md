# Version History — cade

Tracks the platform's release version, not individual milestones or
phases (see `docs/plan/plan.md` M16 "Versioning Policy" — milestones and
phases are implementation stages, not releases).

## 0.3.4 — 2026-09-03

Patch release, no behavior change beyond bug fixes. Fixed Issue #110
(cosmetic `LIVE_PARENT` jq bug in `scripts/verify-repo-identity.sh` —
`gh repo view --json parent` never returns `.parent.nameWithOwner`; the
fork-detected warning now correctly names the real parent repo instead
of printing an empty string). Fixed Issue #107 (the `devcontainer`
template's empty-workspace bootstrap left its inner Coder Agent stuck
`timeout`/never `connected` — the nested devcontainer container couldn't
resolve `host.docker.internal` since neither Coder nor its own
`--add-host=...:host-gateway` point it at the real Coder server; the
bootstrap script now resolves and pins the outer container's real IP as
a literal `--add-host` runArg). Both fixes were live-verified end to end
against the real running stack (before/after `coder show` states, no
mocks) — see PR #112 and PR #113. Filed Issue #114 as a follow-up: the
same `host.docker.internal` gap also affects a *repo-provided*
`devcontainer.json` (not just the bootstrap-generated one), reproduced
live against the real `tbrandenburg/cade` repo's own `.devcontainer/`;
not yet fixed.

## 0.3.3 — 2026-09-03

Patch release, no behavior change beyond a cosmetic workflow fix. Closed
out Issue #102 by executing its required Manual E2E Test for real against
live GitHub state (identity/visibility drift detection, fork detection,
`make doctor` warn-only behavior, `runner-jit-start.sh` resolution, and
`make templates-verify-vars` all confirmed live — see PR #109). Fixed
Issue #102's T7: `.github/workflows/agent-chat.yml`'s `workflow_dispatch`
dry-run `github-url` fallback no longer hardcodes `tbrandenburg/cade` —
it's now computed from `github.server_url`/`github.repository` at
step-body time, so a fork's manual dry-run correctly falls back to its
own repo. Filed Issue #110 as a follow-up (cosmetic `LIVE_PARENT` jq bug
in `scripts/verify-repo-identity.sh`, not fixed in this release).

## 0.3.2 — 2026-09-03

Patch release. Fixed Issue #103 (`srt` sandbox policy silently failed
OPEN — empty, unrestricted policy — whenever `repo_url` pointed at a repo
without `agent-host/srt-settings.json`; the platform's default policy is
now baked into the workspace image at `/etc/cade/srt-settings.default.json`
and used as a fallback). Genericized `repo_url` across all 4 Coder
templates (Issue #104): defaults to empty (bring-your-own-project)
instead of cade's own repo, with a real empty-workspace bootstrap path
added for `devcontainer`. Live-verified (Issue #105) that the existing
manual `github_token`/`GIT_ASKPASS` mechanism successfully clones private
github.com repos on `docker-workspace` and `agent-workspace`. Added a
canonical `REPO_SLUG`/`ASSUMED_VISIBILITY` source of truth plus a
warn-only drift detector wired into `make doctor` (Issue #102). See
PR #106 for full live E2E evidence.

## 0.3.1 — 2026-09-02

Patch release, no behavior change. Fixed Issue #96 (Omnigent
opencode-native terminal EROFS — `agent-host/srt-settings.json`'s
`filesystem.allowWrite` now covers `~/.omnigent`) and removed the
top-of-file `README.md` "Status: vX.Y.Z released" banner, which
duplicated (and regularly drifted out of sync with) the structured,
already-maintained [Project status](README.md#project-status) section
further down the same file.

## 0.3.0 — 2026-09-01

Per-workspace agentic-session sandboxing/bridging, dashboard-app tile
integrations (Temporal, omnigent, JupyterLab, Node-RED), Coder-API-driven
persistent-workspace orchestration, and a round of live-verified
host/template hardening fixes. Highlights since 0.2.0 (Issues #43-#88):

- **omnigent host integration**: per-workspace `omnigent host --background`
  daemon (Issue #43), a reverse Unix-socket bridge working around `srt`'s
  `bwrap --unshare-net` network-namespace isolation so the daemon can
  reach a sandboxed `opencode serve` (Issue #45), and an Omnigent Chat
  dashboard tile ported to both `agent-workspace` and `docker-workspace`
  (Issues #47, #75), plus fixes for the opencode-native "badge" false
  positive and `srt`'s network allowlist (Issues #80, #82).
- **Temporal-owned persistent Coder workspaces**: exec into a pre-existing
  workspace as a build target (Issue #49), full create/resolve/reap
  lifecycle driven entirely through the Coder API with a narrowly-scoped
  `temporal-svc` token (Issue #50), and a Temporal Workflows dashboard
  tile with per-workspace deep-linking (Issue #50 §10).
- **JupyterLab / Node-RED workspace apps**: added as optional dashboard
  tiles (Issue #60), followed by a real root-cause fix once Coder's
  wildcard-DNS subdomain routing became available — replacing an interim
  path-rewriting proxy shim entirely (Issues #62, #76, #81, #83, #86).
- **Template consolidation and drift protection**: retired the stale
  `docker-standard` template in favor of a single canonical
  `docker-workspace` (Issue #67), added `templates-verify-vars` drift
  detection between live Coder template variables and their Terraform
  defaults (Issue #73), and documented the three-tier workspace-app
  convention (Issue #65; see `.agents/skills/coder-app-tile/SKILL.md`).
- **Live-verified fixes discovered via real end-to-end testing**, not
  code review alone: `docker-workspace`'s broken `--disable-ttl` autostop
  flag (Issue #74), `coder` crash-looping on an unset
  `GITHUB_OAUTH_CLIENT_ID` (Issue #71), OpenBao's TLS cert no longer
  needing manual pre-generation (Issue #69), and an OPA `workspace.authz`
  gate for workspace-lifecycle Activities (Issue #54).
- **Documentation**: a new `AGENTS.md`/README section on internal-vs-
  external component placement for platform integrations (Issue #88).

See `AGENTS.md`'s "Lessons Learned" section and the referenced
milestone/issue docs for full evidence of each item above.

## 0.2.0 — 2026-08-30

Coder AI integration and CI agent automation, plus sandboxing/hardening
fixes discovered along the way. Highlights since 0.1.0:

- Coder Agents integration: AI providers/models reconciler
  (`make ai-bootstrap`/`make ai-token`/`make verify-ai`), MCP wiring, and
  a new `agent-workspace` Coder template with OSS `boundary` egress
  control (Issue #13; explored further in Issue #16).
- GitHub external auth (`CODER_EXTERNAL_AUTH_0_*`) and a real
  `.github/workflows/agent-chat.yml` CI workflow that lets a
  `agent-chat`-labeled GitHub issue drive a Coder Agents chat and post
  results back to GitHub (Issue #17).
- Resolved the long-standing `srt`/`bwrap` unprivileged-userns sandbox
  failure with scoped seccomp+AppArmor host security profiles, verified
  live end-to-end including enforcement denial (Issue #23).
- Replaced the devcontainer template's docker-outside-of-docker design
  with per-workspace nested Docker-in-Docker, per Coder's own reference
  guidance (Issues #5/#6).
- Build/governance hardening: OPA `build.authz` gate for
  `run_build_command`, `templates-push` Makefile target, CACERT support
  for corporate TLS-intercepting proxies, print-URLs UX, and assorted
  README/docs fixes (Issues #8-#10, #12).
- Rebranded `devenv-cloud` -> `cade` (Continuous Agentic Development
  Environment) (#3).

See `AGENTS.md`'s "Lessons Learned" section and the referenced
milestone/issue docs (`docs/ai-coder.md`, `docs/security.md`) for full
evidence of each item above.

## 0.1.0 — 2026-08-29

First release. Every Final Acceptance Criteria checkbox (`docs/plan/plan.md`
M16) is satisfied: the Final E2E Test Request (A–L) and all three
Durability Boundary Tests (UI/AHP, Worker/Temporal, Workspace/Coder) pass
against the real stack; a full backup/restore cycle (M14) is verified
against all four MUST BACK UP categories; all 16 milestone reports across
5 phases are committed. See `AGENTS.md`'s Agent Instructions for the
walkthrough and `docs/milestone-reports/` for the underlying evidence.
