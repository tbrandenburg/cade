> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 4 — Governance & Observability

## Gap: Temporal SDK metrics never reach Prometheus — all `temporal_*` panels are empty

Independent review of the closed step
`docs/plan/steps/in-review/00300-observability.md` re-ran the M13
Validation Milestone live (a real `demo.starter --wait` workflow execution
against the running `temporal-worker`/`temporal`/`otel-collector`/
`prometheus` stack) and found the "Temporal activity count" / "Workflow
failures" Minimum Dashboard panels (`observability/grafana/provisioning/
dashboards/files/phase4.json`, queries `sum(temporal_activity_task_received_total)`
and `sum(temporal_workflow_failed_total)`) **never receive data**, even
though the worker exports OTLP metrics and the collector's Prometheus
scrape target reports `health: up`.

`docker logs otel-collector` shows a continuous stream (1000+ occurrences
across the stack's uptime) of:

```
error  prometheusexporter@v0.138.0/collector.go:529  failed to convert
metric temporal_activity_task_received: duplicate label names in constant
and variable labels for metric "temporal_activity_task_received_total"
```

— for every single `temporal_*` metric name the SDK emits (activity,
workflow, request, poller, worker-slot metrics all affected; confirmed via
`docker logs otel-collector | grep -oP 'failed to convert metric \K[a-z_]+' | sort -u`,
23 distinct metric names, all failing). Root cause: the `prometheus`
exporter block in `observability/otel-collector/config.yaml` sets
`resource_to_telemetry_conversion.enabled: true`, which promotes OTel
resource attributes (e.g. `service.name`/`job`) into Prometheus labels —
colliding with an attribute of the same name the Temporal SDK already
attaches directly to each metric. lab-sim's and cadvisor's metrics are
unaffected (they don't emit a colliding attribute), which is why those
dashboard panels work and masked this gap.

Verified fix (tested live, then reverted before closing this review so as
not to hand-edit an in-review step's deliverable): setting
`resource_to_telemetry_conversion.enabled: false` in
`observability/otel-collector/config.yaml` immediately makes
`temporal_activity_task_received_total` queryable in Prometheus with the
correct `activity_type`/`workflow_type`/`task_queue` labels (SDK's own
`job` attribes surface as `exported_job` instead of colliding). Re-ran a
`demo.starter --wait` workflow after the change and confirmed non-zero
values via `curl .../api/v1/query?query=temporal_activity_task_received_total`.

## Actions

1. In `observability/otel-collector/config.yaml`, set
   `resource_to_telemetry_conversion.enabled: false` on the `prometheus`
   exporter (or otherwise resolve the label collision — e.g. an explicit
   `transform`/`attributes` processor renaming the colliding resource
   attribute — but disabling resource-attribute promotion is the minimal
   fix verified above).
2. Update the comment above that config block, which currently justifies
   `enabled: true` for a reason that does not hold given this collision.
3. Restart `otel-collector` and re-run the M13 Validation Milestone: a
   `demo.starter --wait` workflow execution, then confirm both
   `sum(temporal_activity_task_received_total)` and
   `sum(temporal_workflow_failed_total)` (trigger a deliberate activity
   failure to populate the latter, e.g. temporarily point `--build-id` at
   an input the demo activities reject, if the current demo workflow
   supports inducing one — otherwise confirm the metric name at least
   appears in `/api/v1/query?query=temporal_workflow_failed_total` with a
   `0`/absent-but-not-erroring result) return non-empty results from
   Prometheus, matching the `phase4.json` dashboard's exact queries.
4. Confirm `docker logs otel-collector` after the fix is free of
   `failed to convert metric` errors for a fresh workflow execution.
