# Version History — cade

Tracks the platform's release version, not individual milestones or
phases (see `docs/plan/plan.md` M16 "Versioning Policy" — milestones and
phases are implementation stages, not releases).

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
