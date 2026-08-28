# Operations — devenv-cloud

Operational runbooks not covered by the `Makefile` help text.

## Self-hosted runner image rebuild / patch cadence (Milestone M2)

`runner/Dockerfile` is the highest-security-sensitivity image in the
platform (it executes code dispatched from GitHub). It pins:

- the base OS image by digest (`ubuntu:24.04@sha256:...`)
- the GitHub Actions Runner release by version + a hardcoded SHA-256
  checksum verified at build time

Both pins mean the image **will not silently drift** — which also means it
will not silently pick up security patches. Rebuild cadence:

- **Monthly**, at minimum: bump the `ubuntu:24.04` digest to the latest
  digest for that tag (`docker pull ubuntu:24.04 && docker inspect
  --format='{{index .RepoDigests 0}}' ubuntu:24.04`) and re-run
  `make runner-build`.
- **Within 48h of a GitHub Actions Runner security release**: check
  https://github.com/actions/runner/releases, bump `RUNNER_VERSION` and
  `RUNNER_SHA256` (the release asset's own checksum — recompute with
  `sha256sum` on the downloaded tarball since GitHub does not always
  publish it in the release notes body), and re-run `make runner-build`.
- **Immediately** on a disclosed CVE affecting either pin.

Because the runner is JIT/ephemeral (no persistent container), a rebuilt
image takes effect on the very next `scripts/runner-jit-start.sh` /
`runner-smoke.yml` run — no drain/replace procedure is needed.

## Rebuilding the runner image

```
make runner-build
```

Behind a corporate/TLS-intercepting proxy:

```
make runner-build CACERT=/path/to/ca-bundle.pem
```

## Observability stack (Milestone M13)

`docker compose up -d` starts `otel-collector`, `prometheus`, `loki`,
`promtail`, `cadvisor`, and `grafana` alongside the rest of the platform.
Grafana is the only observability service published to the host
(`127.0.0.1:${GRAFANA_PORT:-3001}`, default `http://localhost:3001`,
default credentials `admin` / `${GRAFANA_ADMIN_PASSWORD:-admin}` — change
before any non-local use). Prometheus and Loki are internal-only, reached
through Grafana's provisioned datasources (`prometheus`, `loki` uids).

### Minimum Dashboard layout

Provisioned from `observability/grafana/provisioning/dashboards/files/
phase4.json` (folder "Phase 4 — Observability", dashboard "Phase 4 -
Observability (Minimum Dashboard)"). Panels, top to bottom:

1. **Service uptime** — `time() - container_start_time_seconds{name!=""}`
   (cAdvisor), one series per container name.
2. **Temporal activity count** — `sum(temporal_activity_task_received_total)`.
3. **MCP request count (lab-sim)** — `sum(lab_sim_requests_total)`.
4. **Lab API request count (by tool)** — `sum(lab_sim_tool_calls_total) by (tool)`.
5. **Workflow failures** — `sum(temporal_workflow_failed_total)` (red
   threshold at 1).

### Finding/correlating one execution across services

1. Run the thing you want to trace (e.g. `make temporal-demo-start` for a
   workflow, or an MCP tool call against `lab-sim`) and note the wall-clock
   time.
2. In Grafana, open the Minimum Dashboard and narrow the time range to
   just around that timestamp — the metrics panels show the corresponding
   counter increment.
3. Switch to the **Loki** datasource (Explore, or a Loki panel) and query
   `{container=~"lab-sim|temporal-worker|temporal|runner-health"}`
   restricted to the same time window — every compose container's stdout/
   stderr is shipped there by `promtail` (Docker service discovery against
   `/var/run/docker.sock`, read-only). Correlate the specific request/
   workflow by matching timestamps and identifiers (workflow_id,
   reservation_id, caller_id) that appear in the log lines across the
   different `container` label values.

Prometheus targets (`otel-collector`, `temporal-server`, `temporal-worker`,
`lab-sim`, `cadvisor`) can be checked directly with `docker exec prometheus
wget -qO- http://localhost:9090/api/v1/targets` if a panel shows no data.

