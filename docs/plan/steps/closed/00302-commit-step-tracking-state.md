> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Gap-fill for 00301-commit-final-acceptance-deliverables.md

## Why this matters

A review of the closed step `docs/plan/steps/in-review/00301-commit-final-acceptance-deliverables.md`
found that its own action 4 explicitly deferred committing
`docs/plan/steps/closed/` and `docs/plan/steps/in-review/`, instructing a future
check via `git log --all -- docs/plan/steps/` to see whether this directory tree
is "normally tracked" before adding it. That check has now been done:

```
$ git log --all -- docs/plan/steps/
commit e25ca7c chore(plan): commit M13.1 uncommitted deliverables (report, plan state, screenshot)
    - docs/plan/steps/closed/: previously-closed step files never committed
```

This confirms `docs/plan/steps/closed/` **is** the canonical, previously-tracked
step-tracking state for this repo's factory process (already committed once
before, in `e25ca7c`). Yet as of this review, `git status --short` shows:

```
?? docs/plan/steps/closed/
?? docs/plan/steps/in-review/
```

with 0 files under either directory tracked in the current `HEAD`
(`git ls-files docs/plan/steps/closed | wc -l` → 0,
`git ls-files docs/plan/steps/in-review | wc -l` → 0). This is the exact
recurring pattern this repo's own `AGENTS.md` lessons warn about: "right before
closing a step... an M13.1 review found the milestone report, plan-state
files, and a referenced screenshot all left untracked despite the step being
marked closed/in-review." Step 00301 fixed the docs deliverables but
reproduced the same class of gap for the step-tracking directory itself.

## Actions

1. Run `git status --short` at the repo root to reconfirm the exact current
   set of untracked paths under `docs/plan/steps/` (state may have shifted
   since this gap was filed — more steps may have moved to `closed`/
   `in-review` by the time this runs).
2. Stage and commit `docs/plan/steps/closed/` and `docs/plan/steps/in-review/`
   in one commit, separate from any unrelated changes, e.g.:
   `chore(plan): commit step-tracking state (closed/in-review step files)`.
3. Do NOT touch `docs/plan/steps/planned/` gap-fill files created by other
   review steps unless they are already the canonical tracked location (check
   `git log --all -- docs/plan/steps/planned/` first) — this gap-fill step is
   scoped only to `closed/` and `in-review/`.
4. After committing, re-run `git status --short` on the whole repo to confirm
   no further untracked/modified files remain anywhere under `docs/plan/steps/`.
5. Verify with `git ls-files docs/plan/steps/closed docs/plan/steps/in-review`
   that every file currently on disk under both directories is now tracked in
   `HEAD` (count on disk must equal count in `git ls-files`).
