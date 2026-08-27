# Phase 4 — Governance & Observability

## Phase Objective

Get secrets out of source, prove policy-enforced denials, and make execution across services observable.

Milestones covered: **M9** (Governance Foundation), **M10** (Observability).

Depends on Phase 2 (runner) and Phase 3 (Temporal, MCP) existing, since governance/observability wrap around those execution paths.

---

## M9 — Governance Foundation

Do not build enterprise-scale security. Implement enough to prove the architecture.

### OpenBao

Use for: LLM API secrets, demo device credentials, service credentials. No secret should need to appear in source code.

Once OpenBao is live, rotate every credential introduced during Phases 1–3 under the interim secret handling rule (`.env`-based, per `docs/INITIAL.md` Section 3 Rule 3) and record the rotation here.

### OPA

Implement at least three example policies:

```text
allow read_device
allow run_test
deny flash_device_without_approval
```

### Keycloak

Use only if identity experimentation is required. Otherwise make this service optional through `docker compose --profile governance` — do not enable it by default.

### Validation Milestone M9

Attempt `run_test` → expected: ALLOW. Attempt `flash_device` without approval → expected: DENY.

### Manual E2E Test M9

Intentionally try an unauthorized operation. The test only passes if the system rejects it.

Record in `docs/milestone-reports/M9-governance.md`, including the exact policy decision and the credential-rotation log for anything carried over from Phases 1–3.

---

## M10 — Observability

### Objective

Make executions visible across: GitHub runner, Temporal worker, MCP service, lab simulation.

Deploy: OpenTelemetry Collector, Grafana OSS. Optional additional local backend (Prometheus, Loki, Tempo) — only add those if actually needed.

### Minimum Dashboard

Display: service uptime, Temporal activity count, MCP request count, lab API request count, workflow failures.

### Validation Milestone M10

Execute a sample build, a Temporal workflow, and an MCP request. All three must produce observable telemetry.

### Manual E2E Test M10

1. Execute a complete local test.
2. Open Grafana.
3. Find the execution.
4. Correlate timestamps across services.

Record screenshots/logs in `docs/milestone-reports/M10-observability.md`.

---

## Phase 4 Manual E2E Testing (performed by you, the agent)

You, as the agent, must personally execute every Manual E2E Test in this phase (M9, M10) end-to-end. For M9, attempt the unauthorized operation yourself and confirm OPA actually rejects it — do not accept a policy file review as a substitute for a live denial. For M10, run a real execution yourself and locate it in Grafana by correlating timestamps across services. Capture command output, exit codes, and timestamps per the evidence standard (`docs/INITIAL.md` Section 3, Rule 2), and record results in `docs/milestone-reports/M9-governance.md` and `M10-observability.md` before considering Phase 4 complete.

---

## Phase 4 Exit Criteria

- [ ] OpenBao holds all secrets previously stored in `.env`; no secret remains in source.
- [ ] All Phase 1–3 credentials are rotated once and the rotation is logged.
- [ ] OPA allows `run_test` and denies `flash_device` without approval.
- [ ] Keycloak is either not deployed or gated behind the `governance` compose profile.
- [ ] A single execution (build + Temporal workflow + MCP request) is traceable end-to-end in Grafana.
- [ ] `docs/milestone-reports/M9-governance.md` and `M10-observability.md` are committed with command-level evidence.
