> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## M15 — Local Network / Browser Access (gap-fill)

### Why this gap exists

Step `00700-remote-access-browser-handoff.md` required a full M15 validation
(dashboard + code-server in-browser over the LAN IP, then `coder config-ssh`
+ VS Code Desktop Remote-SSH + an in-workspace build) and a committed
`docs/milestone-reports/M15-local-access.md` recording it. On review:

- `docs/milestone-reports/M15-local-access.md` does not exist anywhere in
  git history — the required report was never written or committed.
- Only validation items 1–2 (Coder dashboard + code-server reachable/editable
  over `http://192.168.0.20:7080`) have any evidence at all, and that
  evidence (`.playwright-mcp/m15-code-server*.png` and console/page logs) is
  **untracked** (`git status` shows `.playwright-mcp/` as `??`) — nothing was
  committed.
- Validation items 3–4 (`coder config-ssh` + VS Code Desktop Remote-SSH to
  `coder.<workspace-name>`, then editing source and running
  `make -C examples/hello-service build` inside that session) have **zero**
  evidence of ever having been attempted.
- A workspace named `m15-e2e` does exist and is currently `Started`/healthy,
  suggesting the browser part of the manual test was run interactively but
  never finished or documented.

This matters because M15 is a milestone with an explicit "Manual E2E Test"
requirement — an unrecorded, half-finished manual test is indistinguishable
from a test that was never run at all, and leaves the audit trail unable to
prove local-network reachability was ever actually validated end-to-end.

### Actions

1. Reuse the existing `m15-e2e` Coder workspace (or recreate it with
   `coder create --yes` passing every `coder_parameter` explicitly, per the
   Lessons Learned in `AGENTS.md`) — do not assume it is still in a good
   state; check `coder list -a` and `coder show m15-e2e` first.
2. Re-verify items 1–2 fresh: from a non-`localhost` vantage point (or at
   minimum via `http://<server-ip>:7080`), open the Coder dashboard and the
   workspace's code-server app in-browser; confirm the repo is visible and
   editable. Capture screenshot(s) under a repo-relative path (e.g.
   `docs/milestone-reports/assets/m15-*.png`), not `.playwright-mcp/`.
3. Run `coder config-ssh` and connect via VS Code Desktop's Remote-SSH (or
   the CLI equivalent `coder ssh m15-e2e` if a GUI Remote-SSH session is not
   available in this environment — but if using the CLI fallback, say so
   explicitly in the report rather than implying a GUI test happened).
4. From that SSH session, edit a source file and run
   `make -C examples/hello-service build`; capture the actual command output.
5. Write `docs/milestone-reports/M15-local-access.md` documenting all four
   validation items with real command output/evidence for each, explicitly
   noting the vantage-point/device used (or the constraint if only the
   server itself was available), and commit it together with any evidence
   assets.
6. Clean up: `coder stop m15-e2e` (or delete) once evidence is captured, and
   ensure no stray `.playwright-mcp/` artifacts are left untracked at repo
   root — either commit them under `docs/milestone-reports/assets/` or
   remove them.
