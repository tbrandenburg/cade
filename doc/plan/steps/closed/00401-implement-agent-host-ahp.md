> Mandatory: read the overall plan in full before proceeding: doc/plan/plan.md
> Gap-fill for: doc/plan/steps/in-review/00400-vs-code-agent-host-ahp.md

# Gap: M4 (VS Code Agent Host + AHP) has zero implementation on disk

## Why this matters

Step `00400-vs-code-agent-host-ahp.md` was moved to `in-review` but **none** of its
required deliverables exist anywhere in the repository, committed or uncommitted:

- `scripts/configure-coder-ssh.sh` — missing
- `scripts/verify-agent-host.sh` — missing
- `scripts/verify-ahp-session.sh` — missing
- `agent-host/settings.json` (with `chat.agent.sandbox.enabled` and
  `chat.sessionSync.enabled: false`) — missing (`agent-host/` directory does not exist)
- `docs/milestone-reports/M4-agent-host.md` — missing
- No autostop/scheduling configuration change for agent-capable workspaces anywhere in
  `coder/` — not found

Independent verification: `git status --short`, `find . -iname '*agent-host*' -o -iname
'*ahp*'`, and `git log --all -- <each path>` all confirm none of these paths were ever
created, tracked, or even present as uncommitted work. This is not a partial gap — it is
a complete non-implementation of the step's every action and its Manual E2E Test.

Per the AGENTS.md lesson from the M0 review (repeated identical gap-fill failures with
no deliverable produced), this single gap-fill step consolidates *all* missing M4
deliverables rather than splitting into several steps, to avoid repeating that failure
pattern.

## Required actions

1. Add `scripts/configure-coder-ssh.sh` that runs `coder config-ssh` (non-interactively,
   e.g. with `--yes` or equivalent flag) to regenerate the SSH config for Coder
   workspaces.
2. Add `scripts/verify-agent-host.sh` that checks the Agent Host process is running and
   reachable over the `coder config-ssh`-generated SSH host, independent of any VS Code
   window being open (e.g. via `ssh coder.<workspace> pgrep -f <agent-host-process>` or
   equivalent).
3. Add `scripts/verify-ahp-session.sh` that performs the actual AHP JSON-RPC-over-WebSocket
   handshake described in the step (WebSocket upgrade, `initialize` call with
   `params: {"protocolVersions":["1.0.0"]}`, and assertion that the response contains
   `protocolVersion`, `serverSeq`, `defaultDirectory`) — not just a port/listening check.
   Reference `docs/POC.md` step 7 / the `ahp-sandbox` findings already cited in the step
   file for the exact protocol shape.
4. Create `agent-host/settings.json` with:
   - `chat.agent.sandbox.enabled: true`
   - `chat.sessionSync.enabled: false`
   and wire it so it is actually applied to `.vscode/settings.json` in the Coder
   workspace template (do not just leave it as an unused file in the repo).
5. Update the Coder workspace template (`coder/templates/docker-workspace/`) so the
   persistent home volume explicitly covers `~/.vscode` and `~/.vscode-server` (in
   addition to whatever it already persists from M3), matching the "Verified paths"
   section of the step file.
6. Add autostop/scheduling handling for agent-capable workspaces (e.g. a
   `coder_parameter`/template flag that disables aggressive autostop when the workspace
   is agent-capable, while normal human-only workspaces keep the default e.g. 4h
   autostop). Document this as a known limitation to revisit with a proper workspace
   lease later, per the step's instructions.
7. Run the Manual E2E Test M4 exactly as specified in `00400-vs-code-agent-host-ahp.md`
   (create workspace, `coder config-ssh`, open Agents window, start session, close
   window, reconnect, confirm session persisted and agent kept working). Capture the
   actual transcript/evidence.
8. Write `docs/milestone-reports/M4-agent-host.md` with the real command output and E2E
   transcript from step 7 — not a restated plan.
9. Commit all new/modified files (scripts, `agent-host/settings.json`, Coder template
   changes, milestone report) so a reviewer can independently verify them with `git log`.
