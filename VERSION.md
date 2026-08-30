# Version History — cade

Tracks the platform's release version, not individual milestones or
phases (see `docs/plan/plan.md` M16 "Versioning Policy" — milestones and
phases are implementation stages, not releases).

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
