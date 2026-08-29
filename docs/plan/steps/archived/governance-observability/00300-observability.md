> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 4 — Governance & Observability

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

