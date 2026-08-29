> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Gap-fill for 00400-e2e-cross-service-trace-correlation

## Why this matters

Step `00400-e2e-cross-service-trace-correlation.md` (M13.1 — E2E:
Cross-Service Trace Correlation) was executed and its evidence recorded in
`docs/milestone-reports/M13-observability.md`, but as of the review of the
closed step, none of the following were committed to git — they exist only
as untracked working-tree files:

- `docs/milestone-reports/M13-observability.md` (the M13.1 evidence section)
- `docs/plan/plan.md`
- `docs/plan/steps/in-review/` (including this step's own closed file)
- `docs/plan/steps/closed/`
- `.playwright-mcp/m13-dashboard-overview.png` (the screenshot referenced by
  the M13.1 evidence as proof of the Grafana dashboard step)

This violates the repo's own binding lesson under "Before trusting any
'blocker' or 'done' claim" in `AGENTS.md`: *"Commit + push every
deliverable as the *first* action of a step, before writing the milestone
report."* A fresh clone of `origin/main` currently has none of this M13.1
evidence, the screenshot, or the plan-state bookkeeping — masking the fact
that the milestone report's claims cannot be independently verified from
the committed repo history alone (only from the live working tree checked
during this review).

## Actions

1. Stage and commit the following paths (verify with `git status --short`
   immediately before committing that no unrelated/unintended files are
   swept in):
   - `docs/milestone-reports/M13-observability.md`
   - `docs/plan/plan.md`
   - `docs/plan/steps/in-review/` (or wherever the now-current plan-state
     tooling expects closed-but-not-yet-reviewed steps to live)
   - `docs/plan/steps/closed/`
   - `.playwright-mcp/m13-dashboard-overview.png` (or move it to a
     permanent evidence location referenced by the milestone report if
     `.playwright-mcp/` is meant to stay gitignored/ephemeral — check
     `.gitignore` first and reconcile the report's relative path
     accordingly).
2. Push the commit(s) to the remote.
3. Re-verify with `git ls-files <path>` for every path above that it is now
   tracked, and `git log --oneline -1 -- <path>` shows a real commit — do
   not just re-save/touch the files.
4. If `docs/plan/steps/closed/` is itself a stage transiently occupied
   before a review moves files elsewhere (check `scripts/factory.sh` or
   the phase README for the intended step-file lifecycle), instead commit
   at whatever stage the tooling defines as final — do not invent a new
   convention.
