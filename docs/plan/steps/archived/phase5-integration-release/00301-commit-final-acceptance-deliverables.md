> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Gap-fill for 00300-final-acceptance-release.md

## Why this matters

A review of the closed step `docs/plan/steps/in-review/00300-final-acceptance-release.md`
found that every deliverable the step claims to have produced is present on disk but
**uncommitted** (`git status --short` at review time):

```
 M AGENTS.md
 M docs/ARCHITECTURE.md
 M docs/operations.md
 M docs/security.md
?? VERSION.md
?? docs/disaster-recovery.md
?? docs/plan/plan.md
?? docs/plan/steps/closed/
?? docs/plan/steps/in-review/
```

Per this repo's own accumulated lessons learned (`AGENTS.md`, "Before trusting any
'blocker' or 'done' claim"): "uncommitted files don't exist for a workspace that clones
from the remote (the single biggest cause of false 'done' claims)". A step that bumps
`VERSION.md` to `0.1.0` and writes the disaster-recovery/AGENTS.md/architecture updates
without committing them means the `0.1.0` release does not actually exist on `origin/main`
— a fresh clone of the repo right now would still show `VERSION.md` as `unreleased` and
would be missing `docs/disaster-recovery.md` entirely.

Note: the underlying content itself (VERSION.md bump rationale, AGENTS.md Phase 5
Lessons Learned entry, ARCHITECTURE.md/operations.md/security.md updates,
disaster-recovery.md) was reviewed and found accurate/complete — this gap is purely
about the missing commit, not about content correctness.

## Actions

1. Run `git status --short` at the repo root to reconfirm the exact current set of
   uncommitted/untracked paths (state may have shifted since this gap was filed).
2. Stage and commit all of the following in one commit (do not bundle unrelated changes):
   - `AGENTS.md`
   - `docs/ARCHITECTURE.md`
   - `docs/operations.md`
   - `docs/security.md`
   - `VERSION.md`
   - `docs/disaster-recovery.md`
   - `docs/plan/plan.md` (if still untracked — confirm this is the intended location per
     this repo's plan-state convention before committing; do not commit if it duplicates
     an already-tracked file elsewhere)
3. Use a conventional-commit message reflecting the M16 final-acceptance/release nature,
   e.g. `docs(m16): commit final acceptance docs, AGENTS.md lessons learned, VERSION 0.1.0`.
4. Do NOT commit `docs/plan/steps/closed/` or `docs/plan/steps/in-review/` as part of this
   gap-fill unless they are the canonical step-tracking state for this factory process —
   verify with `git log --all -- docs/plan/steps/` whether this directory tree is normally
   tracked in this repo before adding it blindly.
5. After committing, re-run `git status --short` on the whole repo (not just the paths
   just committed) to confirm no further untracked/modified files remain from this or an
   adjacent step, per the repo's own lesson: "right before closing a step... an M13.1
   review found the milestone report, plan-state files, and a referenced screenshot all
   left untracked despite the step being marked closed/in-review."
6. Verify `VERSION.md` reads `0.1.0` and `docs/disaster-recovery.md` exists in
   `git show HEAD:docs/disaster-recovery.md` (i.e. actually committed, not just on disk)
   before considering this gap closed.
