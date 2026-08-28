> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Gap: M11 MCP deliverables never committed/pushed

## Why this matters

Step `00400-mcp-and-local-capability-fabric.md` (M11) was reviewed as
functionally complete and independently re-verified end-to-end (docs-server
`stdio` tools work, lab-sim container is up/healthy, full simulated-device
lifecycle reserve→flash→run_test→get_logs→release reproduced independently
against the live HTTP service, unauthenticated/wrong-token requests rejected
with 401, state-handle-hijack attempt rejected with `ReservationOwnershipError`)
— but at review time every deliverable the step's own milestone report
(`docs/milestone-reports/M11-mcp.md`) claims to have built was still
**uncommitted** in the working tree:

```
 M .env.example
 M AGENTS.md
 M compose.yaml
?? docs/milestone-reports/M11-mcp.md
?? mcp/
?? opencode.jsonc
```

This is the exact same defect already documented and fixed once before for
M8 (`docs/plan/steps/closed/00301-commit-m8-temporal-deliverables.md`), and
this repo's own `AGENTS.md` "Lessons Learned" section explicitly warns about
it: *"Commit + push every deliverable as the first action of a step, before
writing the milestone report"* and *"`git status --short` for every path a
step claims to create — uncommitted files don't exist for a workspace that
clones from the remote (the single biggest cause of false 'done' claims)."*
A Coder workspace provisioned from this repo today would clone the *remote*
— none of the M11 MCP work (`mcp/docs-server`, `mcp/lab-sim`, the
`lab-sim` compose service, `opencode.jsonc` tool wiring, `.env.example`
entries) would exist there.

## Actions

1. Re-verify the working tree still matches what `M11-mcp.md` describes
   (re-run `git status --short`, `git diff --stat`) — confirm nothing else
   has drifted in the meantime.
2. Stage and commit exactly the M11-scoped deliverables in one commit (or a
   small number of logically-grouped commits): `compose.yaml`,
   `.env.example`, `opencode.jsonc`, `mcp/docs-server/` and `mcp/lab-sim/`
   (excluding `.venv/` and `__pycache__/`, both already gitignored),
   `docs/milestone-reports/M11-mcp.md`, and the `AGENTS.md` lesson-learned
   bullet. Use a conventional-commit-style message (e.g. `feat(mcp): M11
   MCP and local capability fabric — docs-server + lab-sim`).
3. Push the commit(s) to the remote.
4. Confirm `git status --short` is clean for all M11-scoped paths
   afterward, and that `git log --oneline -1 -- mcp/` shows the new commit.
