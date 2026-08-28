> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Gap: M8 Temporal deliverables never committed/pushed

## Why this matters

Step `00300-temporal-durable-workflow.md` (M8) was reviewed as functionally
complete and independently re-verified end-to-end (stack healthy, worker-kill
durability test passed, permanent-failure non-retryable path confirmed, `make
down && make up` volume persistence confirmed) — but at review time every
deliverable the step's own milestone report (`docs/milestone-reports/M8-temporal.md`)
claims to have built was still **uncommitted** in the working tree:

```
 M .env.example
 M AGENTS.md
 M Makefile
 M compose.yaml
 M docs/milestone-reports/M1-compose.md
?? docs/milestone-reports/M8-temporal.md
?? temporal/
```

This repo's own `AGENTS.md` "Lessons Learned" section already documents why
this is a real defect, not a formality: *"Commit + push every deliverable as
the first action of a step, before writing the milestone report"* and *"`git
status --short` for every path a step claims to create — uncommitted files
don't exist for a workspace that clones from the remote (the single biggest
cause of false 'done' claims)."* A Coder workspace provisioned from this
repo would clone the *remote* — none of the M8 Temporal work (compose
services, worker image source, Makefile targets, `.env.example` entries)
would exist there today.

## Actions

1. Re-verify the working tree still matches what M8-temporal.md and
   M1-compose.md's "M8 addition" section describe (re-run `git status
   --short`, `git diff --stat`) — confirm nothing else has drifted in the
   meantime.
2. Stage and commit exactly the M8-scoped deliverables in one commit (or a
   small number of logically-grouped commits): `compose.yaml`, `Makefile`,
   `.env.example`, `temporal/` (Dockerfile, pyproject.toml, uv.lock,
   `src/demo/*.py` — excluding `.venv/` and `__pycache__/`, both already
   gitignored), `docs/milestone-reports/M8-temporal.md`,
   `docs/milestone-reports/M1-compose.md`, and the `AGENTS.md` Temporal
   lesson-learned bullet. Use a conventional-commit-style message
   (e.g. `feat(temporal): M8 durable orchestration — Temporal compose stack + demo workflow`).
3. Push the commit(s) to the remote.
4. Confirm `git status --short` is clean for all M8-scoped paths afterward,
   and that `git log --oneline -1 -- temporal/` shows the new commit.
