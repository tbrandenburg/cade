> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Gap-fill for 00100-backup-restore.md

## Why this gap matters

Step `00100-backup-restore.md` (M14 — Backup / Restore) was independently
re-verified against the live stack and every functional claim holds:
`scripts/backup.sh` / `scripts/restore-test.sh` work end-to-end, the
restored Coder DB (`select name from workspaces` includes `demo-e2e`),
Temporal DB (`select count(*) from executions` = 23, full Event History
including `WorkflowExecutionCompleted`), OpenBao (unsealed with the
backed-up key shares, `bao kv get secret/devenv-cloud/m14-test` returns
the marker), and the workspace home volume (`/home/coder/m14-marker.txt`
and the `agent/m14-session` worktree's `session-marker.txt`) were all
confirmed byte-for-byte/value-for-value against the real running
containers.

However, `git status --short` at review time showed **every deliverable
this step claims to have created is untracked**:

```
 M .gitignore
 M AGENTS.md
 M Makefile
?? backup/
?? docs/milestone-reports/M14-backup.md
?? scripts/backup.sh
?? scripts/restore-test.sh
```

Per the repo's own `AGENTS.md` "Lessons Learned": *"uncommitted files
don't exist for a workspace that clones from the remote (the single
biggest cause of false 'done' claims)"*. A future workspace/CI run that
clones `origin/main` would have none of `backup/`, `scripts/backup.sh`,
`scripts/restore-test.sh`, the `make backup`/`make restore-test` targets,
or the milestone report — silently breaking the entire M14 capability
despite it having been fully validated locally.

(Note: `docs/plan/plan.md`, `docs/plan/steps/in-review/`, and
`docs/plan/steps/planned/` are also untracked, but those are the
factory's own plan-state files, out of scope for this gap — they are
managed by the plan-review process itself, not by step 00100.)

## Actions

1. Stage and commit exactly the files this step (00100) is responsible
   for:
   - `backup/backup-policy.md`
   - `backup/restore-test.md`
   - `scripts/backup.sh`
   - `scripts/restore-test.sh`
   - `Makefile` (the `backup`/`restore-test` target additions)
   - `docs/milestone-reports/M14-backup.md`
   - The `AGENTS.md` diff, if it is still the pre-existing M14-related
     addition (verify with `git diff AGENTS.md` first — do not commit
     unrelated changes made after this review).
   - `.gitignore` (the `backup/artifacts/` line).
2. Before committing, run `git diff --stat` and confirm no unrelated
   files or secrets (e.g. `governance/openbao/unseal/init.json`,
   `backup/artifacts/`) are staged — both must remain gitignored/absent.
3. Write a concise commit message, e.g. `feat(backup): add M14
   backup/restore scripts, policy, and milestone report`.
4. After committing, run `git status --short` on the whole repo again to
   confirm nothing from this step remains untracked, and confirm a fresh
   `git show HEAD --stat` lists exactly the files above.
