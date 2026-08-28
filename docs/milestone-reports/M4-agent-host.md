# M4 VS Code Agent Host + AHP — Milestone Report

Evidence captured for Phase 1 / Milestone M4 (VS Code Agent Host + AHP), per
the evidence standard in `docs/INITIAL.md` Section 3 Rule 2.

- **Timestamp (UTC):** 2026-08-28T14:12Z
- **Environment:** local Coder server (`ghcr.io/coder/coder:v2.36.3`),
  `docker-workspace` template version `adventurous_duncan01` (built from
  commit `ea7201e`+ M9 additions, workspace image
  `devenv-cloud/coder-workspace:latest`), authenticated as `m3reviewer`.

## Why this report was missing until now

Steps `00401`–`00405` (see `docs/plan/steps/closed/`) repeatedly failed to
produce this report because every workspace-creation attempt assumed
`tbrandenburg/devenv-cloud` was a **private** repository requiring a
`github_token` parameter, and no such credential was available
non-interactively in those sessions.

**Root cause re-checked for this report:** the repository is in fact
**public** —

```
$ gh api repos/tbrandenburg/devenv-cloud --jq '.private, .visibility'
false
public
```

— so `git clone` inside the workspace startup script never needed a token
at all. The credential blocker documented in `00405` no longer applies (and
in retrospect was never the true root cause of the missing report — the
actual gap was simply that no session had completed the "create a workspace
→ run the scripts → write the report" sequence end to end and committed it).

## What was verified

1. **Template matches repo exactly.** `coder templates pull docker-workspace
   /tmp/.../template-pull --yes` diffed byte-for-byte against
   `coder/templates/docker-workspace/` (excluding `.terraform/` and the lock
   file) — zero differences.
2. **Fresh workspace creation, owned by the authenticated user** (per the
   AGENTS.md lesson on ownership mismatches, created as `m3reviewer/m4-e2e`
   rather than reusing the stale `admin/m4-e2e`):

   ```
   $ coder create m4-e2e --template docker-workspace --yes \
       --parameter agent_capable=true --use-parameter-defaults
   ...
   Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
   The m4-e2e workspace has been created at Aug 28 16:10:28!
   ```

3. **Startup script completed successfully with no token:**

   ```
   $ docker exec coder-m3reviewer-m4-e2e cat /tmp/coder-startup-script.log
   Cloning into '/home/coder/project'...
   parsing flags ([schedule stop m4-e2e --disable-ttl]) for "coder schedule stop": unknown flag: --disable-ttl
   ```

   The clone succeeded (public repo, no `GITHUB_TOKEN` set/needed). The
   `coder schedule stop --disable-ttl` line is a **known, pre-existing,
   non-fatal** issue (`|| true` in `main.tf`; the flag doesn't exist in this
   Coder CLI version) — it does not block or fail the rest of the script.

4. **Repo, sandbox settings, and M9 tooling all present in the workspace:**

   ```
   $ docker exec coder-m3reviewer-m4-e2e ls /home/coder/project
   AGENTS.md LICENSE Makefile README.md agent-host coder compose.yaml doc docs examples ...

   $ docker exec coder-m3reviewer-m4-e2e cat /home/coder/project/.vscode/settings.json
   {"chat.agent.sandbox.enabled":true,"chat.sessionSync.enabled":false}

   $ docker exec coder-m3reviewer-m4-e2e ls -la ~/.srt-settings.json
   -rw-r--r-- 1 coder coder 367 ... /home/coder/.srt-settings.json

   $ docker exec coder-m3reviewer-m4-e2e which srt opencode pi tmux
   /usr/bin/srt /usr/local/bin/opencode /usr/bin/pi /usr/bin/tmux
   ```

   Confirms `chat.agent.sandbox.enabled` (VS Code's own sandbox, independent
   of `srt`) and `chat.sessionSync.enabled: false` (Rule 8, session data
   locality) are both applied on first boot, as required by this milestone.

5. **SSH bridge works end-to-end:**

   ```
   $ scripts/configure-coder-ssh.sh
   Regenerating SSH config for Coder workspaces...
   Done. Workspaces are reachable as: ssh coder.<workspace-name>

   $ ssh coder.m4-e2e 'echo SSH_OK; hostname'
   SSH_OK
   m4-e2e
   ```

## Validation Milestone M4

```
$ scripts/verify-agent-host.sh coder.m4-e2e
Checking SSH reachability of coder.m4-e2e...
Checking for a running Agent Host process on coder.m4-e2e...
FAIL: no Agent Host process found on coder.m4-e2e.
This is expected if no Agents-window session has ever been started
against this workspace yet — VS Code starts the Agent Host lazily on
first remote connect, it is not part of the workspace startup script.
```

This is the **correct, expected** result, not a bug: the Agent Host process
is started lazily by VS Code's Agents window on first remote connect (per
`docs/INITIAL.md`'s M4 section and `code.visualstudio.com/docs/agents/run/remote-agent-sessions`).
No VS Code client (GUI) exists in this non-interactive session/environment
to perform that first connect —confirmed independently: no `code`/VS Code
CLI binary is present anywhere in the workspace container
(`find / -iname code -type f` finds only an unrelated AppArmor profile at
`/etc/apparmor.d/code`), and `~/.vscode-server` contains only the empty
directory skeleton created by the `code-server` module, not a real
Agent-Host-capable VS Code server bundle.

```
$ scripts/verify-ahp-session.sh coder.m4-e2e
ERROR: could not discover the Agent Host's listening port on coder.m4-e2e.
Pass it explicitly: scripts/verify-ahp-session.sh coder.m4-e2e <remote-port> [connection-token]
```

Same root cause: nothing is listening because no Agent Host process has
ever been started against this workspace.

## Manual E2E Test M4 (AHP Persistence)

**Not completed — requires a human with a real VS Code Desktop client.**
Steps 3–12 of the Manual E2E Test (open VS Code's Agents window, start an
agent session, close/reopen the window, confirm the session persists) are
inherently interactive: they exercise VS Code's own GUI-driven Agent Host
bootstrap, which cannot be triggered by a headless script or CLI agent —
there is no documented non-interactive way to make VS Code Desktop install
and start its Agent Host bundle against a remote SSH host. This is the same
"no GUI VS Code available" constraint already recorded in the M5 report.

Steps 1–2 (create fresh workspace, `coder config-ssh`) are covered above and
are automatable — a human only needs to pick up from step 3:

1. ~~Create fresh Coder workspace.~~ ✅ (`m3reviewer/m4-e2e`, this report)
2. ~~Configure SSH: `coder config-ssh`.~~ ✅ (this report)
3. Open VS Code Agents window. — **requires human**
4. Select the Coder SSH host (`coder.m4-e2e`). — **requires human**
5. Start an agent session. — **requires human**
6. Give the agent a task that takes long enough to observe. — **requires human**
7. Close the project VS Code window. — **requires human**
8. Wait. — **requires human**
9. Open the Agents window again. — **requires human**
10. Reconnect to the same host. — **requires human**
11. Confirm the same session remains available. — **requires human**
12. Confirm the agent continued while no editor window was attached. — **requires human**

Once a human performs steps 3–12, re-run `scripts/verify-ahp-session.sh
coder.m4-e2e` (now able to auto-discover the listening port) to capture the
protocol-level handshake evidence, and append the result to this report.

## Cleanup

The test workspace was deleted after capturing all evidence above:

```
$ coder delete m4-e2e --yes
...
m4-e2e has been deleted.
```

## Answer to the required question

*Is the Durable Session Plane (VS Code Agent Host / AHP) reachable and
correctly configured, independent of the workspace container and any
specific LLM harness?*

**Partially — infrastructure YES, live session persistence NOT YET
independently verified.** Everything this milestone controls
non-interactively is proven: the workspace clones the (public) repo without
credentials, applies the sandbox/session-locality settings on first boot,
is reachable over SSH as `coder.<workspace-name>`, and the two verification
scripts correctly detect the (expected) absence of a running Agent Host
process. The one property this milestone is actually about — a session
surviving the editor client disconnecting/reconnecting — has not been
demonstrated because it requires a real VS Code Desktop GUI session, which
no automated environment here can drive. This must be completed by a human
before M4 is considered fully closed.
