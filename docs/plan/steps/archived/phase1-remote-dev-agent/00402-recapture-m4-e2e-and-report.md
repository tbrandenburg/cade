> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md
> Gap-fill for: docs/plan/steps/in-review/00401-implement-agent-host-ahp.md

# Gap: M4 code/wiring exists, but the Manual E2E Test was never run and the milestone report was never written

## Why this matters

Step `00401-implement-agent-host-ahp.md` was moved to `in-review` claiming all M4
deliverables were implemented. Independent verification confirms:

- `scripts/configure-coder-ssh.sh`, `scripts/verify-agent-host.sh`,
  `scripts/verify-ahp-session.sh`, `agent-host/settings.json`, and the
  `coder/templates/docker-workspace/main.tf` wiring (`.vscode/settings.json` write-out,
  `agent_capable` parameter, home-volume comment) all exist on disk, are committed
  (`git log --all` shows commit `ea7201e`), and `terraform validate` passes cleanly in
  `coder/templates/docker-workspace/`.
- However, `docs/milestone-reports/M4-agent-host.md` **does not exist** anywhere —
  neither on disk nor in `git log --all -- docs/milestone-reports/M4-agent-host.md`
  (confirmed empty output).
- A pre-existing workspace container (`coder-admin-m4-e2e`) was inspected directly
  (`docker exec ... ps aux`): it only runs `code-server` (port 13337), not a VS Code
  Remote "Agent Host" process, and has no `.vscode/settings.json` in `/home/coder` —
  i.e. this container predates the M4 template changes and is not evidence of the
  step's own Manual E2E Test having been run against the new template.
- Action 7 of the step ("Run the Manual E2E Test M4 exactly as specified... capture the
  actual transcript/evidence") and action 8 ("Write
  `docs/milestone-reports/M4-agent-host.md` with the real command output and E2E
  transcript") were therefore never performed, despite the step being moved to
  `in-review`.

Per the AGENTS.md lesson from the M0 review (repeated identical gap-fill failures with
no deliverable produced) and the M3 review (a report file left byte-for-byte identical
to a stale prior version): this gap-fill's sole scoped purpose is to actually produce
`docs/milestone-reports/M4-agent-host.md` from a real, freshly reproduced E2E run — not
to re-touch the already-verified code/wiring from commit `ea7201e`.

## Required actions

1. Push/deploy the current `coder/templates/docker-workspace/` template (reflecting
   commit `ea7201e`'s `.vscode/settings.json` write-out and `agent_capable` parameter)
   to the running Coder server, and create a **fresh** workspace from it (do not reuse
   the stale `coder-admin-m4-e2e` container, which predates these template changes).
2. Run `scripts/configure-coder-ssh.sh` against the fresh workspace and capture its
   output.
3. Open a VS Code Remote / Agents-window session against the workspace (or the closest
   non-interactive equivalent available in this environment) to actually start an Agent
   Host process, per the Manual E2E Test in `docs/plan/steps/in-review/00400-vs-code-agent-host-ahp.md`.
   If a fully interactive VS Code session cannot be driven non-interactively, document
   exactly what was attempted, what could not be automated, and why — do not fabricate
   a transcript.
4. Run `scripts/verify-agent-host.sh <coder-ssh-host>` and
   `scripts/verify-ahp-session.sh <coder-ssh-host>` against the fresh workspace and
   capture their real output (PASS/FAIL and exit codes).
5. Confirm `/home/coder/.vscode/settings.json` was actually written on the fresh
   workspace with `chat.agent.sandbox.enabled: true` and
   `chat.sessionSync.enabled: false`, and that `~/.vscode` / `~/.vscode-server` survive
   a workspace stop/start cycle (per the home-volume mount).
6. Write `docs/milestone-reports/M4-agent-host.md` containing the real command
   transcripts from steps 1-5 above (successes and any failures/limitations
   encountered), not a restated plan.
7. Commit `docs/milestone-reports/M4-agent-host.md` (and any other newly-produced
   evidence artifacts) so a reviewer can independently verify with `git log`.
