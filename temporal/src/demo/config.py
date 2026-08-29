"""Env-injected connection config, read once at import.

Pattern reused from `tbrandenburg/temporal-sandbox`'s `src/sandbox/config.py`
(see M8 step notes): read connection details from the environment with sane
localhost defaults, so both the starter and the worker import the same
values instead of hardcoding `localhost:7233` anywhere.
"""

import os

# NOTE: use the literal IPv4 address, never bare "localhost" — on hosts
# where "localhost" resolves to "::1" (IPv6) first, the Temporal server
# binds IPv4 only, producing a connection failure that looks like "server
# isn't running" when it's actually a resolution quirk (M8 step notes).
TEMPORAL_ADDRESS = os.environ.get("TEMPORAL_ADDRESS", "127.0.0.1:7233")
TEMPORAL_NAMESPACE = os.environ.get("TEMPORAL_NAMESPACE", "default")

# Shared Task Queue name constant. A Client/Worker Task Queue name mismatch
# does not error — the workflow just silently never gets picked up. Define
# it once here and import it in both the starter and the worker.
TASK_QUEUE = os.environ.get("DEMO_TASK_QUEUE", "demo-durable-workflow")

# M13 Observability: bind address for the Temporal SDK Runtime's built-in
# Prometheus metrics HTTP endpoint (temporal_workflow_completed,
# temporal_workflow_failed, temporal_activity_task_received, etc.).
# Empty string disables telemetry export entirely — used by
# `demo/starter.py`, which does not need a Runtime, and by any standalone
# test run without the observability stack up.
#
# A native Prometheus endpoint (scraped directly by `prometheus`, same
# pattern already used for the Temporal *server*'s own metrics via
# PROMETHEUS_ENDPOINT in compose.yaml) is used here instead of routing
# through otel-collector's OTLP receiver: the collector's
# `prometheusexporter` was observed to drop every one of these metrics
# ("duplicate label names in constant and variable labels") even with
# `resource_to_telemetry_conversion` disabled - a collision between the
# Temporal SDK's own per-metric attributes, not a resource-attribute
# promotion artifact (see AGENTS.md).
METRICS_BIND_ADDRESS = os.environ.get("METRICS_BIND_ADDRESS", "")

# M15 end-to-end scenario: the Lab/Device API (M11 lab-sim MCP service,
# governed by M12's OPA policy) that `e2e_activities.py` calls. Same
# bearer-token scheme as `mcp/lab-sim/.env.example` / `opencode.jsonc`'s
# `devenv-lab-sim` MCP server entry — this worker acts as one more
# authenticated caller ("agent-a"), not a privileged bypass.
LAB_SIM_URL = os.environ.get("LAB_SIM_URL", "http://127.0.0.1:8300/mcp/")
LAB_SIM_AGENT_TOKEN = os.environ.get("LAB_SIM_AGENT_TOKEN", "change-me-a")

# Issue #5 MVP: separate, minimally-privileged Docker socket proxy used
# ONLY by `demo/build_activity.py`'s `run_build_command` Activity to spin
# up ephemeral build containers from `cade/coder-workspace:latest`. Kept
# distinct from any other Docker access this worker might have — do not
# reuse for lab-sim or other capabilities. Defaults to the bare unix
# socket for local/standalone testing outside compose.
BUILD_DOCKER_HOST = os.environ.get("BUILD_DOCKER_HOST", "unix:///var/run/docker.sock")

# Issue #5 gap-fill: OPA base URL for `demo/build_activity.py`'s
# `run_build_command` authorization gate (`build.authz` policy, see
# `governance/opa/policy/build_authz.rego`). Same in-compose service
# hostname default as `mcp/lab-sim/src/lab_sim/policy.py`'s `OPA_URL`;
# override for local/out-of-container testing.
OPA_URL = os.environ.get("OPA_URL", "http://opa:8181")

