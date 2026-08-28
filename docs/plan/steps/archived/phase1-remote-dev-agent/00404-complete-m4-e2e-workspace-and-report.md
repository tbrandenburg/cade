> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md
> Gap-fill for: docs/plan/steps/in-review/00403-recapture-m4-e2e-and-report-again.md

# Gap: template push was finally correct, but workspace creation/verification/report still never happened (fourth consecutive miss)

## Why this matters

Independent re-verification of `00403` shows partial progress but still no completed
deliverable:

- **Good news, confirmed independently**: `coder templates versions list docker-workspace`
  now shows an `Active`/`Succeeded` version (`varied_lang29`), and `coder templates pull
  docker-workspace <dir> --yes` followed by `diff` against
  `coder/templates/docker-workspace/main.tf` in the repo produced **zero diff output** —
  the pushed template is byte-identical to the current M4 source (commit `ea7201e`, which
  includes `agent_capable`, `chat.agent.sandbox.enabled`, and the AHP wiring). So required
  action 1 of `00403` was actually done correctly this time.
- **Still broken**: `coder list` currently reports **"No workspaces found!"** — the stale
  `admin/m4-e2e` workspace was apparently deleted (action 2), but a fresh workspace was
  never created from the now-correct template (action 3 never happened). Consequently
  actions 4-8 (running `scripts/configure-coder-ssh.sh`, `scripts/verify-agent-host.sh`,
  `scripts/verify-ahp-session.sh`, checking `.vscode/settings.json` on a live container,
  attempting the Manual E2E Test, and writing the report) were never attempted.
- `docs/milestone-reports/M4-agent-host.md` **still does not exist** — confirmed via `ls
  docs/milestone-reports/` (only `M0-host.md`, `M1-compose.md`, `M3-coder.md` present) and
  `git log --all -- docs/milestone-reports/M4-agent-host.md` (empty output). This is now
  the **fourth** consecutive step (00401, 00402, 00403, and now this gap) required to
  produce this one file.
- Separately noted but out of scope for this gap (flagged for awareness only): the
  working tree currently has uncommitted moves of several step files between
  `in-progress/`, `planned/`, and `closed/` (e.g. `00301`, `00302`, `00400`, `00401`,
  `00402`), and `AGENTS.md` has uncommitted lesson-learned appends already matching the
  content reproduced above. Do not let this distract from action 7 below, but do not
  clobber these pending moves either — leave them for whichever step is responsible for
  committing them.

Per the repeated-gap escalation pattern established during the M0 review: this is the
fourth attempt at the exact same deliverable. If this gap-fill also fails to produce the
report, the next reviewer must stop creating further identically-scoped gap-fills and
instead flag this as a systemic implementer failure requiring human intervention.

## Required actions

1. Confirm (do not re-push unless missing) that `coder templates versions list
   docker-workspace` shows an `Active` version; if it regressed, re-push per `00403`
   action 1 first.
2. Create a genuinely fresh workspace from the `docker-workspace` template (e.g. `coder
   create admin/m4-e2e-v2 --template docker-workspace --yes`), then confirm with `docker
   ps` / `docker inspect --format '{{ index .Config.Labels "com.coder.workspace_name" }}'
   <container>` that a real, running container backs it (do not trust `coder
   list`/`coder show` status alone).
3. Run `scripts/configure-coder-ssh.sh`, `scripts/verify-agent-host.sh
   <coder-ssh-host>`, and `scripts/verify-ahp-session.sh <coder-ssh-host>` against that
   real workspace and capture their actual PASS/FAIL output and exit codes verbatim.
4. Confirm `/home/coder/.vscode/settings.json` exists inside the live container with
   `chat.agent.sandbox.enabled: true` and `chat.sessionSync.enabled: false` via `docker
   exec <container> cat /home/coder/.vscode/settings.json`.
5. Attempt the Manual E2E Test (VS Code Remote / Agent Host session) from
   `docs/plan/steps/in-review/00400-vs-code-agent-host-ahp.md` (or wherever it now lives
   after the pending file moves settle); if it cannot be driven non-interactively in this
   environment, explicitly document what was attempted, what could not be automated, and
   why — do not fabricate a transcript.
6. Write `docs/milestone-reports/M4-agent-host.md` with the real transcripts/output from
   actions 1-5, including any failures encountered.
7. Commit `docs/milestone-reports/M4-agent-host.md` (and any other new evidence
   artifacts this gap-fill produces) so `git log -- docs/milestone-reports/M4-agent-host.md`
   shows a real commit. Do not commit unrelated pending file moves unless this step is
   also explicitly the one responsible for them.
8. If, after honestly attempting actions 1-7, any action still cannot be completed in
   this non-interactive environment, the report must say so explicitly with the exact
   error encountered — it must not claim success it did not achieve.
