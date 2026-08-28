> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## M4 — VS Code Agent Host + AHP

### Objective

Prove the **Durable Session Plane** independently of both the workspace (M3, Coder) and any specific LLM/agent harness (M9). VS Code's Agent Host owns agent sessions independently of the UI client attached — close the editor, reconnect from another window, and the running host remains the source of truth. Remote Agent Hosts communicate with clients through **AHP (Agent Host Protocol)**, typically over SSH or a dev tunnel.

You probably do not need to package your own Agent Host implementation — VS Code already bundles it. For a remote host, the Coder-provisioned workspace runs it as a standalone process, and VS Code installs/starts the required CLI when making a remote session connection.

**Important qualifier:** an active turn continues while the Agent Host remains running — this does **not** mean the agent survives deletion of its Docker workspace. That's a *workspace* durability question (M3/M6), not a session durability question. See `docs/INITIAL.md` Section 2.2 and Rule 7.

**Enable VS Code's own agent sandbox, not just `srt` (M9).** `chat.agent.sandbox.enabled` is item #1 in VS Code's documented security-baseline checklist and works on Linux/WSL2. Set it in `agent-host/settings.json` as a first OS-level sandbox layer, independent of and complementary to `srt` (introduced in M9) — both should be enabled, not one instead of the other.

### Bridge Coder Workspaces to AHP via SSH

```bash
coder config-ssh
```

Workspaces become reachable as normal SSH hosts (e.g. `ssh coder.my-workspace`). VS Code's Remote Agent Session feature supports AHP over SSH:

```text
VS Code Agents window → AHP over SSH → coder.<workspace-name> → VS Code Agent Host → repo / tools / terminal
```

Add `scripts/configure-coder-ssh.sh` to automate `coder config-ssh`, and `scripts/verify-agent-host.sh` / `scripts/verify-ahp-session.sh` to check the Agent Host process is reachable over the configured SSH host.

**Make `verify-ahp-session.sh` check the actual AHP protocol, not just a listening port.** AHP is JSON-RPC over WebSocket on a plain HTTP-Upgrade endpoint — confirmed hands-on in the independent [`ahp-sandbox`](https://github.com/tbrandenburg/ahp-sandbox) POC (`docs/POC.md` step 7) with nothing but `curl` and a ~20-line Node WebSocket client, no VS Code GUI involved: a bare `curl` hangs (not a normal HTTP server), a WebSocket-upgrade `curl` gets `HTTP/1.1 101 Switching Protocols`, and an `initialize` JSON-RPC call with `params: {"protocolVersions":["1.0.0"]}` returns a real handshake (`protocolVersion`, `serverSeq`, `defaultDirectory`, etc.). Script that handshake instead of only checking the process/port — it actually proves AHP answers, not just that something is listening.

### Persist the Agent Host's Workspace

The persistent home volume from M3 must explicitly include Agent Host state, not just the repo:

```text
Coder workspace container       ephemeral
│
├── /usr/local/toolchain         image
├── /usr/bin/...                 image
│
└── /home/coder                  persistent volume
    ├── project/
    ├── .config/
    ├── .cache/
    ├── .copilot/
    ├── .claude/
    ├── .vscode/cli/servers/Stable-<commit>/   # downloaded server bundle; the Copilot
    │                                          # harness itself lives inside this tree
    ├── .vscode-server/cli/                     # supervisor log
    ├── .vscode-server/data/                    # agent-host user-data-dir, logs/
    └── agent/session state
```

**Verified paths** — confirmed against a live Agent Host process tree in the [`ahp-sandbox`](https://github.com/tbrandenburg/ahp-sandbox) POC: the two directories worth persisting are `~/.vscode` and `~/.vscode-server` as a pair, not a single `~/.vscode-cli` guess (which does not exist). `.copilot`/`.claude` remain separate — those are CLI-tool credential/config dirs (M9), distinct from the Agent Host's own downloaded server bundle.

Do not put the repository or agent session state purely into the ephemeral container filesystem.

### Session Data Locality

Set `chat.sessionSync.enabled: false` in `agent-host/settings.json` / `.vscode/settings.json` (Rule 8) — session history stays local to the private server by default.

### Coordinate Coder's Lifecycle with Active Agent Sessions

Coder's autostop/scheduling is driven by IDE/SSH/terminal activity; there's no confirmed guarantee that Agent Host activity alone counts toward idle detection. A workspace could autostop while an agent is still working with no editor attached.

For the first implementation: disable aggressive autostop on **agent-capable** workspaces specifically, while keeping normal autostop (e.g. 4 hours) on human-only workspaces. Document this as a known limitation to revisit with a proper workspace lease later.

### Validation Milestone M4

`scripts/verify-agent-host.sh` confirms the Agent Host process is running and reachable over the `coder config-ssh`-generated host, independent of any VS Code window being open.

### Manual E2E Test M4 (AHP Persistence)

1. Create fresh Coder workspace.
2. Configure SSH: `coder config-ssh`.
3. Open VS Code Agents window.
4. Select the Coder SSH host.
5. Start an agent session.
6. Give the agent a task that takes long enough to observe (e.g. a multi-minute build).
7. Close the project VS Code window.
8. Wait.
9. Open the Agents window again.
10. Reconnect to the same host.
11. Confirm the same session remains available.
12. Confirm the agent continued while no editor window was attached.

Record in `docs/milestone-reports/M4-agent-host.md`.
