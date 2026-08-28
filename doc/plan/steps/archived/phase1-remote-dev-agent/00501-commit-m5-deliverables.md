> Mandatory: read the overall plan in full before proceeding: doc/plan/plan.md

# Gap-fill for step 00500-agent-session-persistence-worktrees

## Why this matters

Independent review of closed step `00500-agent-session-persistence-worktrees.md`
found that every deliverable it claims to have produced exists **only in the
local working tree**, uncommitted and unpushed:

```
$ git log --all --oneline -- scripts/create-agent-worktree.sh scripts/cleanup-agent-worktree.sh sessions/ docs/milestone-reports/M5-sessions.md
(no output)

$ git status --short scripts/create-agent-worktree.sh scripts/cleanup-agent-worktree.sh sessions/ docs/milestone-reports/M5-sessions.md
?? docs/milestone-reports/M5-sessions.md
?? scripts/cleanup-agent-worktree.sh
?? scripts/create-agent-worktree.sh
?? sessions/
```

This is the exact same class of gap already documented twice in `AGENTS.md`
under the M3 review lessons learned (step 00300 and step 00301): the
`docker-workspace` Coder template clones the **remote** repository into
`~/project` on every workspace, not the local working tree. Because these
files were never committed/pushed, any real Coder workspace created from
the remote right now would have **no** `scripts/create-agent-worktree.sh`,
`scripts/cleanup-agent-worktree.sh`, or `sessions/worktree-policy.md` at
all — the milestone's actual scripts would be completely absent from a real
agent's environment, even though this review independently re-ran the full
Validation Milestone and Manual E2E Test against a fresh workspace using
the *local* copies of these scripts and confirmed every check passes
(worktree isolation, cleanup safety, idempotency, and repository-memory
persistence across a `coder stop`/`coder start` cycle all reproduced
exactly as the milestone report describes).

The implementation itself is correct and fully verified — this gap is
purely about the deliverables never having been committed and pushed to
the remote the template actually clones from.

## Actions

1. `git add scripts/create-agent-worktree.sh scripts/cleanup-agent-worktree.sh sessions/ docs/milestone-reports/M5-sessions.md` (and any other untracked M5-related paths under these directories) and commit with a concise conventional-commit message (e.g. `m5: add agent worktree isolation scripts, policy, and milestone report`).
2. Push the commit so the remote the `docker-workspace` template clones from is up to date.
3. Re-verify by creating a **fresh** Coder workspace from the template and confirming, over SSH, that `~/project/scripts/create-agent-worktree.sh`, `~/project/scripts/cleanup-agent-worktree.sh`, and `~/project/sessions/worktree-policy.md` exist in the freshly cloned checkout (not just locally) before declaring this gap closed. Clean up the test workspace afterward.
4. Do not re-run the full Validation Milestone / Manual E2E Test again — this review already reproduced every check successfully against the local scripts; only the commit/push/fresh-clone verification above is required.
