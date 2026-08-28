> Gap-fill step for 00301-commit-m3-deliverables.md (review finding).

# Gap: `docs/milestone-reports/M3-coder.md` was never re-captured after M3 deliverables were committed and pushed

## Why this matters

Step `00301-commit-m3-deliverables.md` required (actions 2 and 3):

> 2. Re-run the full Validation Milestone M3 and Manual E2E Test M3 sequence
>    **against a freshly created workspace cloning the now-updated remote**, end to
>    end, and re-capture real command transcripts (do not reuse the existing
>    `docs/milestone-reports/M3-coder.md` transcript, since it cannot be reproduced
>    as-is).
> 3. Update `docs/milestone-reports/M3-coder.md` with the corrected, reproducible
>    transcript, keeping the existing "GitHub push credentials" caveat...

Independent re-verification during this review found that `docs/milestone-reports/M3-coder.md`
is **byte-for-byte identical** to the version committed in `5a33d27` (the same
"Commit M3 deliverables" commit that added the file to git for the first time):

```
$ git show 5a33d27:docs/milestone-reports/M3-coder.md > /tmp/m3_committed.md
$ diff /tmp/m3_committed.md docs/milestone-reports/M3-coder.md
(no output — files are identical)
$ git log --oneline --all -- docs/milestone-reports/M3-coder.md
5a33d27 Commit M3 deliverables (Makefile, compose, coder template, examples, scripts, docs)
```

There is only ever **one** commit touching this file. It still contains the
original transcript with timestamp `2026-08-28T11:32Z` and workspace names
`m3-test`/`m3-e2e` — the exact transcript step 00301 itself identified as
"describing an impossible workflow" and explicitly said not to reuse. Actions 2
and 3 of 00301 were never actually performed; only action 1 (committing/pushing
the files) and action 4 (the `Makefile` uncommitted-tree guard, commit `3de638a`)
were completed.

Separately, while probing the currently running Coder deployment to attempt an
independent fresh-workspace check, a leftover workspace container
(`coder-admin-m3-review-verify`) was found with **no** `/home/coder/project`
directory at all (`ls /home/coder/project` → "No such file or directory"), and
its `coder-script-*.log` shows no `git clone` activity, only the `code-server`
install log. This container may be an artifact of a prior, incomplete
verification attempt and is further evidence that the "fresh workspace clone
works end-to-end" claim has not actually been re-demonstrated since the commit/push.

## Required actions

1. Investigate and clean up (or explain) the orphaned `coder-admin-m3-review-verify`
   workspace/container that has no cloned repository — determine whether the
   `coder_agent` clone step in `coder/templates/docker-workspace/main.tf` is
   reliably clone-ing `repo_url` on workspace start, or whether it silently no-ops
   under some conditions (e.g. missing branch, auth prompt, race with the
   startup script). Fix the template if a real defect is found.
2. Delete any stale/orphaned test workspaces from the Coder deployment
   (`coder delete <name> --yes` for each) before capturing the new evidence, so
   the report reflects a clean run.
3. Re-run the full Validation Milestone M3 sequence end-to-end against a
   **newly created** workspace, using the repository state as of commit
   `3de638a` (or later) on the actual remote (`origin/main`):
   - `make coder-workspace-build`
   - `coder templates push docker-standard --directory coder/templates/docker-workspace --yes`
   - `coder create admin/<new-name> --template docker-standard --yes`
   - Inside the workspace: `git status`, `git log -1`, confirm `examples/`,
     `coder/`, `Makefile`, `compose.yaml` are present in the clone.
   - `make -C examples/hello-service build` and `make -C examples/hello-service test`.
4. Re-run the Manual E2E Test M3 table (steps 1-9) against that same fresh
   workspace and capture the real, current transcript — including the
   already-known "GitHub push credentials" limitation for step 9 if it still
   applies.
5. Overwrite `docs/milestone-reports/M3-coder.md` with the new transcript and a
   new timestamp, replacing the stale `2026-08-28T11:32Z` / `m3-test` / `m3-e2e`
   content. Do not just re-word the existing file — every command output shown
   must have actually been produced by the run in steps 3-4 above.
6. Delete the test workspace(s) created for this re-capture afterwards, per the
   existing "Cleanup" section convention.
