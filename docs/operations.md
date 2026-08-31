# Operations — cade

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

## Backup / Restore (Milestone M14)

```
make backup          # bash scripts/backup.sh [name]
make restore-test     # bash scripts/restore-test.sh [name]
```

See `docs/disaster-recovery.md` for the full procedure, what is/isn't
backed up, and the OpenBao `file`-backend deviation from the plan's
literal Raft-snapshot wording.

## Final Acceptance / Full End-to-End Scenario (Milestone M16)

See `AGENTS.md`'s "Agent Instructions" section for the step-by-step
walkthrough of the Final E2E Test Request (A–L) and the three Durability
Boundary Tests (UI/AHP, Worker/Temporal, Workspace/Coder).

## Workspace apps: JupyterLab and Node-RED (Issue #60)

Two independent, opt-in dashboard tiles on the `docker-standard`
(`docker-workspace`) template, both off by default. Each app runs as a
plain in-workspace process (baked into `cade/coder-workspace:latest` at
build time by `coder/Dockerfile`, launched at workspace start by a
`coder_script`), bound to `127.0.0.1` inside the workspace container only.
**Neither app has its own login** — the only way to reach either is
through Coder's own authenticated agent/session proxy. Nothing is
published to the host or the platform's Docker networks.

### Enabling

- At workspace create time: `--parameter enable_jupyter=true` and/or
  `--parameter enable_nodered=true`.
- On an already-existing workspace (no delete/recreate needed):
  ```bash
  scripts/set-workspace-jupyter.sh <owner>/<workspace>            # enable
  scripts/set-workspace-jupyter.sh <owner>/<workspace> false      # disable
  scripts/set-workspace-nodered.sh <owner>/<workspace>            # enable
  scripts/set-workspace-nodered.sh <owner>/<workspace> false      # disable
  ```
  Both wrap the generic `scripts/set-workspace-parameter.sh` (same
  mechanism already used by `scripts/set-workspace-temporal-tile.sh`) —
  this stops (if running) and restarts the workspace container with the
  new parameter value; `docker_volume.home_volume` is untouched
  (Durability Test 3 applies).

### Where data lives

- JupyterLab: notebooks/files under `/home/coder/project` (the same
  cloned-repo directory every other tool in the workspace uses) —
  persistent home volume.
- Node-RED: flows/credentials under `/home/coder/.node-red` — persistent
  home volume. Palette nodes (including
  `@flowfuse/node-red-dashboard`/`@tbrandenburg/node-red-agents`) are
  installed globally at image-build time (`/usr/lib/node_modules`), not
  per-workspace — a brand-new home volume needs zero network access for
  the palette to be available.

### Where logs are

- `/tmp/jupyter.log`, `/tmp/node-red.log` inside the workspace container
  (`docker exec <container> tail -f /tmp/jupyter.log`).
- Coder's own `coder_script` log panel on the workspace page (each app's
  own script, isolated from the other and from the base
  `coder_agent.main.startup_script`).

### Verifying live

```bash
scripts/verify-workspace-jupyter.sh <owner>/<workspace>
scripts/verify-workspace-nodered.sh <owner>/<workspace>
```

Checks: `coder_app` slug presence, process liveness, loopback-only
listener, proxied HTTP round trip (with vs. without a session token), and
(Node-RED only) that the dashboard/agents palettes are discovered and
`/flows` returns real JSON.

### Known limitation: JupyterLab's browser UI

Live-verified (Issue #60): Coder's real path-based `coder_app` proxy
strips the `/@owner/workspace.../apps/<slug>` prefix before forwarding to
the app — it does not preserve the full path, and sends no
`X-Forwarded-Prefix` header. JupyterLab's own JavaScript/CSS is served at
Domain-absolute paths (`/static/lab/...`), so once the browser is
navigated to the tile's prefixed URL, those absolute asset requests
resolve outside the app's own proxy scope and fail to load — the page
loads but renders without its own bundle. Node-RED is unaffected (its
assets use relative paths). Interim workaround:
`coder port-forward <workspace> --tcp 8888:8888` and open
`http://localhost:8888/lab` directly (bypasses the dashboard proxy
entirely). See `docs/milestone-reports/issue-60-jupyter-nodered.md` and
this issue's "Follow-up issues found" for the full evidence and possible
future fixes (wildcard DNS + `subdomain = true`, or an in-workspace
path-rewriting shim).


