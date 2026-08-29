> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 4 — Governance & Observability

## M12.1 — E2E: Governance Denial Proof

Intentionally try an unauthorized operation against the live OPA decision endpoint (not a policy-file review, not `opa test` alone). The test only passes if the system rejects it in a live run.

Record in `docs/milestone-reports/M12-governance.md`, including the exact policy decision and the credential-rotation log for anything carried over from Phases 1–3.
