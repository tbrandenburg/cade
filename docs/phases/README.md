# Implementation Phases — Index

This directory splits `docs/INITIAL.md` into five sequential delivery phases. Each phase document is self-contained (objective, tasks, validation, manual E2E test, milestone reports) for the milestones it covers. The full architectural rules, repository structure, and make-target contract that apply across all phases remain defined once in `docs/INITIAL.md` Sections 3–5 — do not duplicate them; refer back.

| Phase | File | Milestones | Deliverable |
|---|---|---|---|
| 1 | [phase-1-remote-dev-agent.md](./phase-1-remote-dev-agent.md) | M0, M1 (partial: Coder only), M3, M6, M11 | A remote, Docker-based dev workspace reachable from anywhere via Tailscale, with a grounded coding agent (OpenCode or Pi) able to diagnose repo issues. No GitHub automation, Temporal, or governance required yet. |
| 2 | [phase-2-github-automation.md](./phase-2-github-automation.md) | M2, M7 | GitHub can trigger deterministic CI and repository-centric agent reasoning (`gh-aw`) on the private server, outbound-only. |
| 3 | [phase-3-durable-orchestration.md](./phase-3-durable-orchestration.md) | M1 (remainder: Temporal), M5, M4, M8 | Durable workflows survive worker failure; agents/humans call controlled capability APIs instead of arbitrary shell. |
| 4 | [phase-4-governance-observability.md](./phase-4-governance-observability.md) | M9, M10 | Secrets out of source, policy-enforced denials, cross-service telemetry. |
| 5 | [phase-5-integration-release.md](./phase-5-integration-release.md) | Final E2E scenario, Final acceptance criteria, Versioning | Full integrated end-to-end proof and `0.1.0` release. |

## Why this split

The original milestone order (M0→M11 sequential) groups the agent-facing developer experience (M3, M6) behind infrastructure that isn't actually required for it (M2 runner, M5 Temporal). This phase split reorders delivery so that **Phase 1 alone already produces a usable, demoable outcome**: a remote development environment with an AI agent. GitHub automation (Phase 2), durable orchestration and capability fabric (Phase 3), governance/observability (Phase 4), and full integration (Phase 5) are layered on afterward, each independently valuable and independently testable.

## Cross-cutting references (apply to every phase)

- **Section 3 — Core Architectural Rules** (`docs/INITIAL.md`): Docker-first, one repo as source of truth, never commit secrets (incl. interim secret handling before OpenBao exists), GitHub as coordination plane, tool responsibility separation, no arbitrary external access.
- **Section 4 — Repository Structure** (`docs/INITIAL.md`): the full target repo layout; each phase only creates the subset of paths relevant to its milestones.
- **Section 5 — Standard Make Targets** (`docs/INITIAL.md`): the stable `make` interface, including required script test coverage (`shellcheck` + `bats`).
- **Section 21 — Development Workflow**: one milestone per branch, PR, and merge only after acceptance criteria pass — this applies within every phase.
