# Handover — Phase 4: Governance & Observability

## a. Executive summary

Phase 4 adds two capabilities on top of the existing devenv-cloud platform
(remote dev environments, GitHub self-hosted runner, Temporal durable
orchestration, MCP lab-simulation service):

1. **Governance (M12/M12.1)** — secrets are no longer allowed to live in
   source code, and privileged actions against the simulated lab hardware
   are now policy-gated instead of hardcoded. OpenBao (a Vault fork) holds
   credentials behind a TLS listener; Open Policy Agent (OPA) evaluates a
   real Rego policy (`allow read_device`, `allow run_test`,
   `deny flash_device_without_approval`) before the MCP lab-sim server
   will execute a privileged tool call.
2. **Observability (M13/M13.1)** — every execution path (GitHub runner,
   Temporal worker, MCP lab-sim service, and the containers themselves) now
   emits metrics/logs that are collected centrally and visualized in a
   single Grafana dashboard, so a real workflow run can be traced across
   services by timestamp instead of grepping five separate container logs.

Both milestones were validated live against the running stack (no mocks,
no stubs, no skipped steps) as part of this handover — see evidence below.

## b. What works — with evidence

| Feature | Evidence |
|---|---|
| OPA policy engine live-enforces `run_test` = ALLOW and `flash_device` (unapproved) = DENY, verified via `opa test` **and** a real MCP tool round trip (reserve → run_test → flash_device denied → flash_device approved → release) | [`01-governance-verify.txt`](01-governance-verify.txt) |
| OpenBao TLS listener up, unsealed, serving secrets to services; private key permission hardened to `0640` | see `docs/security.md` M12 section; `openbao` container `Up` in dashboard screenshot below |
| Temporal durable workflow executes end-to-end (`prepared:… -> verified:prepared:…`) via the real worker container, not a local stub | [`02-temporal-workflow.txt`](02-temporal-workflow.txt) |
| Full telemetry pipeline (OTel Collector → Prometheus/Loki → Grafana) — Temporal activity count, MCP request count (721 requests captured live), per-tool lab API request breakdown, workflow failure count, and container uptime for all 18 running services, all populated with real, non-zero data from the run above | [`03-grafana-phase4-dashboard.png`](03-grafana-phase4-dashboard.png) |
| Cross-service trace correlation (build + Temporal workflow + MCP request, correlated by timestamp in Grafana) | recorded previously in `docs/milestone-reports/M13-observability.md` (M13.1 section), reproduced live again above |

## c. How to build and run

1. Clone the repository and `cd` into it.
2. Copy `.env.example` to `.env` and adjust `GRAFANA_ADMIN_PASSWORD` if desired.
3. `make doctor` — verify the host meets baseline requirements.
4. `make up` — start the control plane (Postgres + Coder). Then
   `docker compose up -d` for the remaining Phase 2–4 services (runner
   proxy, registry, Temporal, MCP lab-sim, governance, observability).
5. `make governance-bootstrap` — initializes/unseals OpenBao and rotates
   credentials (one-time; OpenBao does **not** auto-unseal across
   container restarts — rerun this if `openbao` shows `unhealthy` in
   `docker compose ps`).
6. `make governance-verify` — runs the same live OPA/MCP proof captured
   in `01-governance-verify.txt`.
7. `make temporal-worker-build && make temporal-demo-start` — builds and
   runs one Temporal workflow execution (as captured in
   `02-temporal-workflow.txt`).
8. Open Grafana at `http://127.0.0.1:3001` and view dashboard
   **"Phase 4 - Observability (Minimum Dashboard)"** (as captured in
   `03-grafana-phase4-dashboard.png`) to see the metrics from steps 6–7
   land within seconds.

## d. How to test

| Action | Expected result |
|---|---|
| `bash scripts/verify-governance.sh` | `opa test` reports `PASS: 6/6`; `run_test` decision returns `{"result":true}`; `flash_device` (unapproved) returns `{"result":false}`; MCP round trip completes with `flash_device (unapproved): is_error=True` and `flash_device (approved): is_error=False` |
| `docker run --rm --network platform-control -e TEMPORAL_ADDRESS=temporal:7233 -e DEMO_TASK_QUEUE=demo-durable-workflow --entrypoint python devenv-cloud/temporal-worker:latest -m demo.starter --wait` | Prints a `workflow_id=… run_id=…` line followed by `result=prepared:… -> verified:prepared:…` |
| Query Prometheus for `sum(temporal_activity_task_received)` after running the workflow above | Returns a non-empty vector with a value greater than 0 (not the pre-fix empty result caused by the OTel label collision) |
| Open `http://127.0.0.1:3001/d/phase4-observability` in a browser | All 5 panels (service uptime, Temporal activity count, MCP request count, lab API request count by tool, workflow failures) render non-zero data, refreshed every 10s |
| `curl -X POST http://127.0.0.1:8181/v1/data/lab/authz/allow -d '{"input":{"action":"flash_device","approved":false}}'` | `{"result":false}` |

## e. Known limitations

- OpenBao does **not** auto-unseal across a container restart/recreate —
  operators must rerun `scripts/openbao-init.sh` (or `make
  governance-bootstrap`) whenever the container is recreated, or it stays
  sealed and reports `unhealthy`.
- Keycloak identity integration is optional and disabled by default
  (`docker compose --profile governance`) — not exercised in this
  handover; only OpenBao + OPA are validated.
- Prometheus's port is intentionally not published to the host (internal
  network only, per its own security guidance) — dashboard/API access
  goes through Grafana or `docker exec` into the `prometheus` container,
  not `curl localhost:9090` from the host.
- The observability stack's `temporal_*` metric names are unsuffixed
  (e.g. `temporal_activity_task_received`, not `..._received_total`)
  because of a known upstream Temporal Python SDK quirk with
  `PrometheusConfig(counters_total_suffix=True)` — any new dashboard panel
  must query the un-suffixed name.
- This is a local/demo-scale deployment (single Docker host, no HA, no
  paid cloud infra) — governance and observability prove the architecture
  works, not that it is hardened for a multi-tenant production
  environment.
