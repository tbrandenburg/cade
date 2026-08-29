> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Gap-fill for 00401-commit-m13-1-uncommitted-deliverables

## Why this matters

Independent review of the closed step
`docs/plan/steps/in-review/00401-commit-m13-1-uncommitted-deliverables.md`
found that its own listed actions were fully and correctly completed (all
four paths committed and pushed in `e25ca7c`, confirmed present on
`origin/main`). However, the working tree at review time still has two
unrelated, real content deliverables sitting modified-but-uncommitted:

- `AGENTS.md` — several "Lessons Learned" bullets recorded during M12/M13
  work (the M13.1 uncommitted-deliverables pitfall itself, the
  `.playwright-mcp/` `git add -f` requirement, the otelcol-contrib
  `resource_to_telemetry_conversion` label-collision findings, and the
  Temporal `PrometheusConfig` counter-suffix finding).
- `docs/operations.md` — a new "Observability stack (Milestone M13)"
  section documenting the Grafana/Prometheus/Loki layout and the
  cross-service trace-correlation procedure, produced by step
  `00400-e2e-cross-service-trace-correlation.md` / `00302-fix-otel-collector-
  temporal-metric-label-collision.md`.

This repeats, in miniature, the exact pitfall `00401` was created to fix:
a fresh clone of `origin/main` has neither of these documentation updates,
so the very lessons/instructions future steps depend on (e.g. the
otel-collector label-collision fix, the observability runbook) are
invisible outside this working tree.

## Actions

1. `git status --short` on the whole repo immediately before committing
   to confirm exactly `AGENTS.md` and `docs/operations.md` are the only
   unstaged/untracked content changes being swept in (do not sweep in
   step-file bookkeeping under `docs/plan/steps/` — that lifecycle is
   managed separately).
2. Commit `AGENTS.md` and `docs/operations.md` with a conventional-commit
   message reflecting that these are M12/M13 documentation updates.
3. Push to `origin/main`.
4. Verify with `git log origin/main..HEAD --oneline` (must be empty) and
   `git diff origin/main -- AGENTS.md docs/operations.md` (must be empty).
