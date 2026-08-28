> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 4 — Governance & Observability

## Gap: M13 observability deliverables are entirely uncommitted

Independent review of the closed step
`docs/plan/steps/in-review/00300-observability.md` found that every file
this step claims to have created is **untracked or unstaged in git**:

- `observability/` (entire directory: OTel Collector config, Prometheus
  config, Loki config, Promtail config, Grafana provisioning +
  `phase4.json` dashboard) — untracked (`??`)
- `compose.yaml` (otel-collector/prometheus/loki/promtail/cadvisor/grafana
  services, volumes) — modified, unstaged
- `.env.example` (`GRAFANA_ADMIN_PASSWORD`, `GRAFANA_PORT`) — modified,
  unstaged
- `mcp/lab-sim/src/lab_sim/server.py`, `pyproject.toml`, `uv.lock`
  (`/metrics` endpoint, `prometheus-client` dependency) — modified,
  unstaged
- `temporal/src/demo/worker.py`, `config.py` (OTLP metrics export wiring)
  — modified, unstaged

This repeats the exact pitfall already recorded in this repo's own
`AGENTS.md` (and previously found for M12 in
`docs/plan/steps/closed/00201-commit-push-m12-governance-deliverables.md`):
*"Commit + push every deliverable as the first action of a step, before
writing the milestone report."* A fresh clone of `origin/main` would have
none of this observability stack and would fail every live check the
in-review step's Validation Milestone requires.

## Actions

1. Confirm no secret material would be committed (Grafana admin password
   stays in `.env`, not `.env.example`; no OpenBao/OPA material is
   touched by this diff).
2. `git add` and commit, in a commit that matches this repo's
   conventional-commit style:
   - `observability/` (all files)
   - `compose.yaml`
   - `.env.example`
   - `mcp/lab-sim/src/lab_sim/server.py`
   - `mcp/lab-sim/pyproject.toml`
   - `mcp/lab-sim/uv.lock`
   - `temporal/src/demo/worker.py`
   - `temporal/src/demo/config.py`
3. Push to `origin/main` and verify with
   `git log origin/main..HEAD --oneline` (must be empty) and
   `git ls-files observability/ | wc -l` (must be non-zero).
4. Do this **after** `00302-fix-otel-collector-temporal-metric-label-collision.md`
   is resolved, so the commit reflects a working pipeline, not the
   currently-broken one.
