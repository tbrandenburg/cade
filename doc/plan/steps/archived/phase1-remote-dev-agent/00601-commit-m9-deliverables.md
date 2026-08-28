> Mandatory: read the overall plan in full before proceeding: doc/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## Gap-fill for 00600-agent-harness-integration.md

### Objective

The M9 milestone report (`docs/milestone-reports/M9-agent.md`) documents a
thorough, working implementation and claims all deliverables exist and pass
validation. Independent review found that **every single deliverable this
step claims to have produced exists only as an uncommitted working-tree
change** — none of it is in `git log --all`:

```text
?? agent-host/srt-settings.json
?? docs/milestone-reports/M9-agent.md
?? scripts/verify-agent-tmux-session.sh
 M coder/Dockerfile                          (uncommitted diff)
 M coder/templates/docker-workspace/main.tf   (uncommitted diff)
```

This is the exact same gap first documented in the M3 review (steps
00300/00301, which took **three** gap-fill attempts to actually resolve —
see AGENTS.md "Lessons Learned" 2026-08-28 entries) and again in the M5
review (step 00500). The Coder workspace template clones the **remote**
repository, not the local working tree — so a real `coder create` against
this repo today would produce a workspace with none of `srt`, `tmux`,
`opencode`/`pi`, `agent-host/srt-settings.json`, or
`scripts/verify-agent-tmux-session.sh`, directly contradicting the
milestone report's transcript (which was captured, per its own text,
against a locally rebuilt image — not what the committed repo would
actually produce for anyone else).

Since this is now the **third occurrence** of the identical class of gap
across three different milestones (M3, M5, M9), do not simply repeat the
same "commit the files" instruction as if this were novel — treat it as a
signal that deliverables must be committed as the very last action of
every step, before any milestone report is written, not after.

### Actions

1. Review the uncommitted working-tree changes relevant to M9:
   - `agent-host/srt-settings.json` (new file)
   - `docs/milestone-reports/M9-agent.md` (new file)
   - `scripts/verify-agent-tmux-session.sh` (new file)
   - `coder/Dockerfile` (modified: `bubblewrap`/`socat`/`ripgrep`/`tmux`,
     `opencode`/`pi` CLI install, `srt` install)
   - `coder/templates/docker-workspace/main.tf` (modified: startup script
     now provisions `~/.srt-settings.json` and the `opencode`/`pi` `srt`
     aliases)
   Confirm each still matches what the milestone report describes (no
   unrelated drift since the report was written).
2. `chmod +x scripts/verify-agent-tmux-session.sh` if not already
   executable, and confirm `bash -n scripts/verify-agent-tmux-session.sh`
   passes (syntax check).
3. Stage and commit exactly these M9 files (do not bundle unrelated
   changes) with a message following this repo's conventional-commit style,
   e.g. `m9: commit agent/harness integration deliverables (srt, tmux,
   opencode/pi)`.
4. Rebuild the workspace image from the now-committed `coder/Dockerfile`
   (`make coder-workspace-build` or equivalent) and push the updated
   `docker-workspace` template so the live template matches the committed
   `main.tf` (`coder templates pull docker-workspace <dir> --yes` afterward
   to diff and confirm zero drift, per the pattern established in the M4
   review of step 00403).
5. Re-run the Manual E2E Test end-to-end against a **freshly created**
   workspace built from the pushed template and a **fresh clone** of the
   now-updated remote (not the pre-existing local working tree), to prove
   the committed repo actually reproduces the milestone report's claims:
   - `which tmux opencode pi srt bwrap` all resolve.
   - `opencode run --model opencode/big-pickle ...` against a seeded
     failure (steps 3-6 of the Manual E2E Test).
   - Re-confirm the known `srt`/`bwrap` sandbox-enforcement limitation is
     still the case in this fresh workspace (do not assume the prior
     report's finding on this still holds without re-checking).
6. If the fresh-workspace re-run diverges in any way from the existing
   `docs/milestone-reports/M9-agent.md`, update the report to reflect the
   real, fresh-clone-based results (surgical edit, since this is the
   report this same milestone is responsible for — not an immutable closed
   step file).
7. Confirm via `git status --short` (clean) and `git log --all -- <path>`
   (each path now present) that every M9 deliverable, including the
   milestone report itself, is committed.
