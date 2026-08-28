# M5 Agent Session Persistence & Worktrees — Milestone Report

Evidence captured for Phase 1 / Milestone M5 (Agent Session Persistence &
Worktrees), per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2
and `docs/plan/plan.md` (M5 section).

- **Timestamp (UTC):** 2026-08-28T13:07Z
- **Environment:** local Coder server (`ghcr.io/coder/coder:v2.36.3`),
  `docker-workspace` template (commit `ea7201e`), authenticated as
  `m3reviewer` (the `admin` account owning the pre-existing `m4-e2e`
  workspace was not accessible to this session, so a fresh workspace
  `m3reviewer/m5-e2e` was created from the same template for this test).

## What was built

- `scripts/create-agent-worktree.sh` — creates `~/worktrees/<session-name>`
  on a Coder workspace (over SSH, matching the M4 scripts' pattern), on a
  new branch `agent/<session-name>` off the main checkout at `~/project`.
  Idempotent: re-running with the same `session-name` reuses the existing
  worktree instead of failing.
- `scripts/cleanup-agent-worktree.sh` — removes a session's worktree
  directory and (unless `--keep-branch`) its branch. Never touches the main
  checkout beyond `git worktree remove`/`git branch -D`. Idempotent: a
  no-op if the worktree is already gone. Refuses to remove a worktree with
  uncommitted changes unless `--force` is passed.
- `sessions/worktree-policy.md` — documents the `1 agent session = 1
  worktree` policy, the "code isolation boundary, not a security sandbox"
  caveat, the distinction from VS Code's native Worktree-isolation mode
  (Bypass-Approvals-only), and how memory (repository/user, persisted on
  the M4 home volume) is orthogonal to worktrees (code isolation).

## Validation Milestone M5

1. **Start two agent sessions** — simulated as two worktrees on the same
   workspace, standing in for two parallel Agent Host sessions (this
   environment does not have GUI VS Code available to drive real Agent
   Host sessions non-interactively; see "Known limitation" below):

   ```
   $ scripts/create-agent-worktree.sh coder.m5-e2e session-001
   Created worktree for session 'session-001':
     path:   /home/coder/worktrees/session-001
     branch: agent/session-001
     base:   main

   $ scripts/create-agent-worktree.sh coder.m5-e2e session-002
   Created worktree for session 'session-002':
     path:   /home/coder/worktrees/session-002
     branch: agent/session-002
     base:   main
   ```

2. **Have each modify the same file differently:**

   ```
   $ ssh coder.m5-e2e "echo '# session-001 edit' >> ~/worktrees/session-001/README.md; \
                        echo '# session-002 edit' >> ~/worktrees/session-002/README.md"
   ```

3. **Confirm they're operating in separate worktrees:**

   ```
   $ ssh coder.m5-e2e "git -C ~/project worktree list"
   /home/coder/project                ea7201e [main]
   /home/coder/worktrees/session-001  ea7201e [agent/session-001]
   /home/coder/worktrees/session-002  ea7201e [agent/session-002]

   $ ssh coder.m5-e2e "tail -1 ~/worktrees/session-001/README.md; tail -1 ~/worktrees/session-002/README.md; tail -1 ~/project/README.md"
   # session-001 edit
   # session-002 edit
   MIT — see [LICENSE](LICENSE).
   ```

4. **Confirm neither silently overwrites the other's working tree:** each
   worktree's `git status --short` shows only its own edit:

   ```
   $ ssh coder.m5-e2e "git -C ~/worktrees/session-001 status --short"
    M README.md
   $ ssh coder.m5-e2e "git -C ~/worktrees/session-002 status --short"
    M README.md
   ```

   PASS — the two sessions' edits coexist independently; neither worktree's
   `README.md` diff leaked into the other, and `~/project/README.md` was
   never touched.

## Manual E2E Test M5

1. **Create two agent worktrees** — done above (session-001, session-002).
2/3. **Start a session in each / edit the same file differently** — done
   above (steps 1–2 of Validation Milestone).
4. **Confirm both edits exist independently with no cross-contamination** —
   confirmed above (step 3–4 of Validation Milestone).
5. **Clean up both worktrees and confirm the main checkout is unaffected:**

   ```
   $ scripts/cleanup-agent-worktree.sh coder.m5-e2e session-001 --force
   Removed worktree /home/coder/worktrees/session-001.
   Deleted branch agent/session-001 (was ea7201e).
   Main checkout at /home/coder/project unaffected:
   ## main...origin/main

   $ scripts/cleanup-agent-worktree.sh coder.m5-e2e session-002 --force
   Removed worktree /home/coder/worktrees/session-002.
   Deleted branch agent/session-002 (was ea7201e).
   Main checkout at /home/coder/project unaffected:
   ## main...origin/main

   $ ssh coder.m5-e2e "git -C ~/project status --short; git -C ~/project worktree list"
   ?? .vscode/
   /home/coder/project  ea7201e [main]
   ```

   PASS — `~/project` only ever shows its own pre-existing untracked
   `.vscode/` (written by the M4 startup script), never any trace of the
   two sessions' edits or branches. `git worktree list` shows both worktree
   entries gone.

   Additional coverage exercised (not required by the step, but validated
   for robustness): re-running cleanup on an already-removed worktree is a
   no-op success (idempotency); re-running create on an existing worktree
   reuses it instead of erroring (idempotency); cleanup without `--force`
   on a worktree with uncommitted changes correctly refuses
   (`fatal: ... contains modified or untracked files, use --force`);
   passing a session name with a space is rejected up front
   (`ERROR: session-name 'bad name' must match [a-zA-Z0-9._-]+`).

6. **Confirm repository memory persists across a session boundary:**

   A repository-level note was written under the persistent Coder home
   volume path introduced in M4 (`~/.vscode-server/.../globalStorage`,
   parallel to where VS Code's own Copilot chat/session data would live if
   `chat.sessionSync.enabled` were true, which per Rule 8 it is not — see
   `agent-host/settings.json`):

   ```
   $ ssh coder.m5-e2e "mkdir -p ~/.vscode-server/data/User/globalStorage/agent-memory/repository && \
                        echo 'Repo note: use pnpm not npm.' > ~/.vscode-server/data/User/globalStorage/agent-memory/repository/notes.md"
   ```

   The workspace was then **stopped and started** (`coder stop m5-e2e` /
   `coder start m5-e2e`), which destroys and recreates the
   `docker_container.workspace` resource entirely — the strongest available
   proxy in this environment for "end a session, start a new one," since it
   proves the note survives even a full container replacement, not just an
   in-process restart:

   ```
   $ coder stop m5-e2e --yes
   ... docker_container.workspace[0]: Destruction complete after 1s ...
   The m5-e2e workspace has been stopped.

   $ coder start m5-e2e --yes
   ... docker_container.workspace[0]: Creation complete after 1s [id=2e7e738...] ...
   The m5-e2e workspace has been started.

   $ ssh coder.m5-e2e "cat ~/.vscode-server/data/User/globalStorage/agent-memory/repository/notes.md"
   Repo note: use pnpm not npm.
   ```

   PASS — the note survived the container replace because it lives on
   `docker_volume.home_volume`, the same persistent volume M4 established,
   not on the ephemeral container filesystem.

## Known limitation

This environment has no GUI VS Code client available to drive real VS Code
Agent Host sessions non-interactively (same constraint noted in the M4
report for AHP handshake testing). The worktree isolation and
memory-persistence properties were therefore proven directly against the
underlying primitives (`git worktree`, the persistent home volume) that a
real Agent Host session would use once pointed at
`~/worktrees/<session-name>`, rather than by literally opening two Agents
windows. `scripts/verify-ahp-session.sh` (M4) remains the tool for
protocol-level AHP verification once a GUI client is available; this
milestone's own scripts (`create-agent-worktree.sh`,
`cleanup-agent-worktree.sh`) are orthogonal to that transport layer by
design (see `sessions/worktree-policy.md`).

## Cleanup

The test workspace was deleted after capturing all evidence above:

```
$ coder delete m5-e2e --yes
m3reviewer/m5-e2e has been deleted.
```
