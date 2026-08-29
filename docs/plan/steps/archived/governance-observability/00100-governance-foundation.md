> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 4 — Governance & Observability

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

