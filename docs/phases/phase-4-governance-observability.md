# Phase 4 — Governance & Observability

## Phase Objective

Get secrets out of source, prove policy-enforced denials, and make execution across services observable.

Milestones covered: **M12** (Governance Foundation) + **M12.1** (E2E), **M13** (Observability) + **M13.1** (E2E).

Depends on Phase 2 (runner) and Phase 3 (Temporal, MCP) existing, since governance/observability wrap around those execution paths.

## Required Reading (mandatory, before starting Phase 4)

| Milestone | Tool | Required reading |
|---|---|---|
| M12 | OpenBao | https://openbao.org/docs/internals/security/, https://developer.hashicorp.com/vault/docs/concepts/production-hardening (conceptually applicable — OpenBao is a Vault fork with no separate hardening checklist of its own) |
| M12 | OPA | https://www.openpolicyagent.org/docs/policy-language, https://www.openpolicyagent.org/docs/policy-performance |
| M12 | Keycloak | https://www.keycloak.org/server/configuration-production, https://www.keycloak.org/server/containers |
| M13 | OpenTelemetry Collector | https://opentelemetry.io/docs/security/config-best-practices/, https://opentelemetry.io/docs/security/hosting-best-practices/ |
| M13 | Prometheus | https://prometheus.io/docs/operating/security/, https://prometheus.io/docs/practices/naming/ |
| M13 | Grafana OSS | https://grafana.com/docs/grafana/latest/best-practices/ |

---

## M12 — Governance Foundation

Do not build enterprise-scale security. Implement enough to prove the architecture.

### OpenBao

Use for: LLM API secrets, demo device credentials, service credentials. No secret should need to appear in source code.

**Baseline hardening (non-negotiable per both OpenBao's security model and Vault's hardening guide):** configure TLS on the listener even for this local/demo deployment (self-signed cert acceptable — eavesdropping is explicitly in-scope of the threat model), and revoke the initial root token after configuring auth methods/policies. Record where unseal key shares (or the auto-unseal KMS reference) are stored — never in git, and cover that location in M14's backup plan.

Once OpenBao is live, rotate every credential introduced during Phases 1–3 under the interim secret handling rule (`docs/INITIAL.md` Section 3 Rule 3) and record the rotation here.

### OPA

Implement at least three example policies. These names describe required *behavior* — real Rego source is needed alongside them, evaluated via OPA's decision API:

```text
allow read_device
allow run_test
deny flash_device_without_approval
```

```rego
package lab.authz

default allow := false

allow if { input.action == "read_device" }
allow if { input.action == "run_test" }
allow if { input.action == "flash_device"; input.approved == true }
```

The MCP lab-server (Phase 3, M11) queries this decision endpoint before executing a privileged action; do not hardcode the allow/deny logic in the MCP server itself.

**Add `opa test` unit tests, not just manual/curl checks** — `opa test` is OPA's standard mechanism for pinning ALLOW/DENY behavior against regressions. Add `lab_authz_test.rego` covering `run_test` (allow), `flash_device` with/without `approved` (allow/deny), and `read_device` (allow); run it as part of M12's validation.

### Keycloak

Use only if identity experimentation is required. Otherwise make this service optional through `docker compose --profile governance` — do not enable it by default.

**If enabled, avoid Keycloak's own documented anti-pattern:** use `start` (not `start-dev`, which Keycloak's own docs say "should be strictly avoided in production... insecure defaults") and set `KC_BOOTSTRAP_ADMIN_PASSWORD` from a generated/rotated secret, not a hardcoded default.

### Validation Milestone M12

Attempt `run_test` → expected: ALLOW. Attempt `flash_device` without approval → expected: DENY.

## M12.1 — E2E: Governance Denial Proof

Intentionally try an unauthorized operation against the live OPA decision endpoint (not a policy-file review, not `opa test` alone). The test only passes if the system rejects it in a live run.

Record in `docs/milestone-reports/M12-governance.md`, including the exact policy decision and the credential-rotation log for anything carried over from Phases 1–3.

---

## M13 — Observability

### Objective

Make executions visible across: GitHub runner, Temporal worker, MCP service, lab simulation, Agent Host sessions.

Deploy: OpenTelemetry Collector + **Prometheus (required metrics storage backend)** + Grafana OSS (visualization only — Grafana has no built-in ingestion/storage; it queries a backend). "OTel Collector → Grafana" alone is not a complete pipeline. Add Loki (logs) and/or Tempo (traces) if the Manual E2E Test's cross-service timestamp correlation needs more than metrics — likely, since it explicitly requires correlating across GitHub runner / Temporal worker / MCP service / lab simulation.

**Binding and exposure — mandatory, not optional:**

- Bind the OTel Collector's receivers to the compose service hostname, not `0.0.0.0` (OpenTelemetry's own docs name unrestricted-interface binding as a tracked DoS risk, CWE-1327), and add a `memory_limiter` processor so it can't OOM relaying telemetry from five services at once.
- **Never publish Prometheus's port to the host/public network** — Prometheus's security docs open with an explicit warning against this; keep it reachable only from Grafana/the Collector on the internal Docker network.
- **Provision the Minimum Dashboard as version-controlled JSON** (e.g. `observability/grafana/dashboards/phase4.json`), not an ad hoc UI-created dashboard — per Grafana's own dashboard-as-code guidance and this repo's Rule 2 (repo as source of truth).

### Minimum Dashboard

Display: service uptime, Temporal activity count, MCP request count, lab API request count, workflow failures.

### Validation Milestone M13

Execute a sample build, a Temporal workflow, and an MCP request. All three must produce observable telemetry.

## M13.1 — E2E: Cross-Service Trace Correlation

1. Execute a complete local test (build + Temporal workflow + MCP request).
2. Open Grafana.
3. Find the execution.
4. Correlate timestamps across services.

Record screenshots/logs in `docs/milestone-reports/M13-observability.md`.

---

## Phase 4 Manual E2E Testing (performed by you, the agent)

You, as the agent, must personally execute every E2E step in this phase (M12.1, M13.1) end-to-end. For M12.1, attempt the unauthorized operation yourself and confirm OPA actually rejects it — do not accept a policy file review or `opa test` alone as a substitute for a live denial. For M13.1, run a real execution yourself and locate it in Grafana by correlating timestamps across services. Capture command output, exit codes, and timestamps per the evidence standard (`docs/INITIAL.md` Section 3, Rule 2), and record results in `docs/milestone-reports/M12-governance.md` and `M13-observability.md` before considering Phase 4 complete.

---

## Phase 4 Documentation & Agent Instructions Update

Before Phase 4 is considered done, you, as the agent, must:

1. **Update project docs** — update `docs/security.md` with the actual OpenBao/OPA setup (secret paths, policy files, credential rotation record) and `docs/operations.md` with the Grafana dashboard layout and how to correlate a request across services.
2. **Update `AGENTS.md`** at the repo root with:
   - **Guidelines** — any new binding rule discovered (e.g. OPA policy authoring conventions, OpenBao unseal/auth quirks, what telemetry fields are actually useful vs. noise).
   - **Agent Instructions** — how to fetch a secret from OpenBao for local testing, how to check an OPA decision manually, and how to find a given execution in Grafana.
   - **Lessons Learned** — a dated entry (`## Phase 4 — <date>`) covering what broke, what surprised you, and what to avoid next time. Append; do not overwrite prior entries.

---

## Phase 4 Exit Criteria

- [ ] OpenBao holds all secrets previously stored in `.env`; no secret remains in source. Listener uses TLS, initial root token revoked, unseal keys backed up outside git.
- [ ] All Phase 1–3 credentials are rotated once and the rotation is logged.
- [ ] OPA allows `run_test` and denies `flash_device` without approval, backed by an `opa test` suite pinning both outcomes.
- [ ] Keycloak is either not deployed, or gated behind the `governance` compose profile and running with `start` (not `start-dev`) and a generated admin password.
- [ ] Prometheus is not exposed on a public/host port; OTel Collector receivers are bound to internal hostnames, not `0.0.0.0`.
- [ ] The Minimum Dashboard is provisioned from version-controlled JSON, not click-ops.
- [ ] A single execution (build + Temporal workflow + MCP request) is traceable end-to-end in Grafana.
- [ ] `docs/milestone-reports/M12-governance.md` and `M13-observability.md` are committed with command-level evidence.
- [ ] `docs/security.md` and `docs/operations.md` reflect the actual Phase 4 implementation.
- [ ] `AGENTS.md` has updated Guidelines, Agent Instructions, and a dated Phase 4 Lessons Learned entry.
