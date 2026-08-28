> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md
> Gap-fill for: docs/plan/steps/in-review/00402-recapture-m4-e2e-and-report.md

# Gap: second gap-fill still did not produce the M4 milestone report or a valid E2E run

## Why this matters

Step `00402-recapture-m4-e2e-and-report.md` was itself a gap-fill created to fix
`00401-implement-agent-host-ahp.md` (code/wiring implemented, but Manual E2E Test never
run and `docs/milestone-reports/M4-agent-host.md` never written). Independent
re-verification of `00402` shows it repeated the exact same failure, plus introduced a
new one:

- `docs/milestone-reports/M4-agent-host.md` **still does not exist** — confirmed via
  `ls docs/milestone-reports/` (only `M0-host.md`, `M1-compose.md`, `M3-coder.md`
  present) and `git log --all -- docs/milestone-reports/M4-agent-host.md` (empty
  output). Required actions 6 and 7 of `00402` were not performed, for the third time
  running (M0 required three attempts before this same class of gap was actually
  closed — see the 2026-08-28 M0 lessons above).
- A workspace named `admin/m4-e2e` does exist in `coder list`/`coder show`, but:
  - It was built from template **`docker-standard`**, not the M4-updated
    `docker-workspace` template that carries the `.vscode/settings.json` write-out and
    `agent_capable` parameter from commit `ea7201e`. Required action 1 ("push/deploy the
    current `coder/templates/docker-workspace/` template... create a fresh workspace
    from it") was not done — `coder templates versions list docker-workspace` returns
    "Resource not found", proving that template was never pushed to the running Coder
    server at all.
  - Its agent is reported `disconnected` / "agent has lost connection", and `docker ps
    -a` (including `docker inspect ... com.coder.workspace_name`) shows **no matching
    container exists** for it in Docker at all — it is a stale/orphaned Terraform
    state, not a live, inspectable workspace.
  - Consequently none of required actions 2-5 (`scripts/configure-coder-ssh.sh`,
    `scripts/verify-agent-host.sh`, `scripts/verify-ahp-session.sh`,
    `.vscode/settings.json` verification on a live container) could have been performed
    against a valid M4 workspace.

Per the AGENTS.md pattern from prior repeated-gap reviews: do not spawn another
identically-worded gap-fill. This step must explicitly diagnose *why* the report keeps
not getting written and *why* the template keeps not getting pushed, before repeating
the same actions.

## Required actions

1. Push the `coder/templates/docker-workspace/` template to the running Coder server
   (`coder templates push docker-workspace -d coder/templates/docker-workspace`, or the
   Makefile target that wraps it if one exists — check `Makefile` first). Verify with
   `coder templates versions list docker-workspace` that a new, non-outdated version
   exists.
2. Delete the stale `admin/m4-e2e` workspace (`coder delete admin/m4-e2e`) since it is
   orphaned (no backing container) and built from the wrong template.
3. Create a genuinely fresh workspace from the now-pushed `docker-workspace` template
   and confirm with `docker ps` / `docker inspect ... com.coder.workspace_name` that a
   real, running container backs it.
4. Run `scripts/configure-coder-ssh.sh`, `scripts/verify-agent-host.sh
   <coder-ssh-host>`, and `scripts/verify-ahp-session.sh <coder-ssh-host>` against that
   real workspace and capture their actual PASS/FAIL output and exit codes.
5. Confirm `/home/coder/.vscode/settings.json` exists inside the live container with
   `chat.agent.sandbox.enabled: true` and `chat.sessionSync.enabled: false` (e.g. via
   `docker exec <container> cat /home/coder/.vscode/settings.json`).
6. Attempt the Manual E2E Test (VS Code Remote / Agent Host session) from
   `docs/plan/steps/in-review/00400-vs-code-agent-host-ahp.md`; if it cannot be driven
   non-interactively in this environment, explicitly document what was attempted, what
   could not be automated, and why — do not fabricate a transcript.
7. Write `docs/milestone-reports/M4-agent-host.md` with the real transcripts/output
   from steps 1-6, including any failures encountered, and commit it (and any other new
   evidence artifacts) so `git log -- docs/milestone-reports/M4-agent-host.md` shows a
   real commit.
8. If, after honestly attempting steps 1-7, any action still cannot be completed in
   this non-interactive environment, the report must say so explicitly with the exact
   error encountered — it must not claim success it did not achieve.
