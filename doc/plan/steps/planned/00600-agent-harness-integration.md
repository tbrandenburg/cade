> Mandatory: read the overall plan in full before proceeding: doc/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## M9 — Agent/Harness Integration

### Objective

Introduce the Agent/Harness Plane on top of the now-proven Session Plane (M4/M5) and Development Execution Plane (M3), using the CLIs already installed and verified on this platform:

```text
opencode   (OpenCode CLI, v1.18.21)
pi         (Pi CLI, v0.84.2)
```

Install both into the agent workspace — not optional, since both are the supported harnesses for this platform.

**Known gap: `opencode`/`pi` do not run through AHP.** M4's Agent Host/AHP durability (session survives closing/reopening the editor window) is only proven for VS Code's own built-in harnesses — Copilot, Claude, and (experimental) Codex are the only agent implementations that plug into the Agent Host process; `agent-host-protocol`'s only server implementation is VS Code's, with no extension point for third-party CLIs. Neither `opencode` nor `pi` is an AHP adapter, so they run as plain terminal processes inside the workspace (wrapped by `srt`), not inside the Agent Host. Do not report M9 as inheriting M4's AHP persistence proof — it doesn't. Re-verify against `code.visualstudio.com/docs/agents/run/agent-harnesses` before assuming this has changed.

### Session Continuity Without AHP: `tmux`/`screen`

Since `opencode`/`pi` can't get durability from AHP, give them an equivalent property directly on the Coder workspace: a detached multiplexer session that keeps running whether or not a client (VS Code, SSH terminal) is attached, backed by the same persistent home volume as M4/M5.

```bash
# start (or reattach to) a named session for a given agent worktree
tmux new-session -A -s agent-session-001 -c ~/project/worktree/session-001

# inside it, run the wrapped harness as usual
opencode   # or: pi
```

- Name sessions after the worktree (M5's `1 agent session = 1 worktree` rule), e.g. `agent-session-001`, so `tmux ls` maps 1:1 to `worktree/session-NNN`.
- Install `tmux` in `coder/Dockerfile` alongside M9's `bubblewrap`/`socat`/`ripgrep`.
- Persist `~/.tmux` config (if any) under the M4 persistent home volume, not the ephemeral container filesystem.
- This proves **process continuity** (the agent keeps running, reconnect later, no separate durability claim needed) — not AHP's multi-client sync, remote handoff, or VS Code Agents-window session list. Don't conflate the two: `tmux` continuity is a Coder-workspace property (M3/M4's volume + a live SSH host), same category as workspace durability, not a new instance of session-plane durability.
- Add `scripts/verify-agent-tmux-session.sh` (reattach after disconnect, confirm the wrapped harness process is still the same PID) alongside M4's `verify-ahp-session.sh`, and cover it in M9's Manual E2E Test below.

### Optional: Copilot as a Third, AHP-Native Harness

If a later requirement needs AHP's specific UX for `opencode`/`pi`-class interactive sessions (e.g. a non-technical reviewer watching/steering from the VS Code Agents window without SSH access, or cross-device handoff via M15's dev-tunnel bridge), add VS Code's built-in **Copilot** harness as a third, optional option rather than replacing `opencode`/`pi`:

- Copilot is the only harness (besides experimental Codex) that plugs directly into the Agent Host process, so it's the only one of the three that actually inherits M4's proven AHP durability out of the box — no `tmux` workaround needed.
- Credentials are close to free here: GitHub Copilot is already the recommended **Backend Model Provider** below, so the same GitHub auth context covers both the model backend and the Copilot harness.
- Keep `opencode`/`pi` as the standardized, automatable harnesses for M9's Agent Test and M10's `gh-aw` (which needs a CLI engine, not VS Code's Agent Host) — Copilot-the-harness is additive for interactive AHP use cases, not a dependency of those milestones.
- Do not add it speculatively. Treat this as backlog until a concrete use case names the AHP-specific capability it needs; adding a third harness means a third credential store and a third `denyRead`/`srtAllowedDomains` entry to validate in every M9 test (see "`denyRead` must include the agent's own credential stores" below `~/.copilot`).

### Backend Model Provider

Choose exactly one initial provider for the first pass:

```text
GitHub Copilot
OR
Claude
OR
OpenAI
OR
Gemini
```

Do not integrate four providers simultaneously. Recommended first option: **GitHub Copilot**, because GitHub is already the coordination plane (Rule 4). Store the provider credential per the interim secret handling rule (Rule 3) — `.env` with `chmod 600`, never committed, rotated once OpenBao exists (Phase 4, M12).

### Zero-Configuration Starting Point: `opencode/big-pickle`

Before setting up any of the above paid providers, start with `opencode`'s built-in `opencode/big-pickle` model — it requires **no API key and no environment variable**:

```bash
opencode run --model opencode/big-pickle "Say hello in exactly 3 words."
```

Confirmed working with a completely clean environment (no `ANTHROPIC_*`, `OPENAI_*`, `COPILOT_*`, `OPENCODE_*` variables set). Use this to validate M9's mechanics (agent sees repo context, diagnoses a seeded failure) first, before spending setup time on provider authentication — then swap in the chosen paid provider above for production use. This is `opencode`-specific; `pi` still needs its own provider configured since it doesn't ship an equivalent no-auth default. (Note: this was confirmed via a direct manual test in this environment, not against `pi`'s or opencode's public documentation, since no authoritative public doc enumerating opencode's zero-config model catalog or pi's CLI reference was located during review — re-verify if either CLI's provider catalog changes.)

### Sandbox Agent CLIs with Anthropic Sandbox Runtime (srt)

Run `opencode` and `pi` wrapped in [Anthropic's Sandbox Runtime](https://github.com/anthropic-experimental/sandbox-runtime) (`srt`) — an OS-level sandbox (`bubblewrap` on Linux, no container-in-container) that enforces filesystem and network allowlists on the wrapped process tree. This is defense-in-depth on top of the workspace container itself: it stops a compromised or misbehaving agent session from reading `~/.ssh`/`.env` or exfiltrating to an arbitrary host, even with a shell inside the workspace. **Status:** beta research preview from Anthropic — an additional layer, not a replacement for the workspace/runner isolation already required by Rule 1/Rule 6.

**Install** (needs Node.js, already required by M3's Workspace Contents):

```bash
npm install -g @anthropic-ai/sandbox-runtime
```

**Workspace image preconditions** — add to `coder/Dockerfile`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    bubblewrap socat ripgrep \
    && rm -rf /var/lib/apt/lists/*
```

**Host/Docker nested-sandbox precondition** — `bubblewrap` runs nested inside the already-containerized workspace, which needs unprivileged user namespaces at the host kernel level:

1. Check `sysctl kernel.unprivileged_userns_clone` on the private server; must be `1`.
2. On **Ubuntu 24.04+ hosts**, AppArmor restricts unprivileged user namespaces by default even when the sysctl above is set — run `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` on the host (or install a scoped AppArmor profile granting `userns` to `bwrap`/`node` instead of a system-wide disable).
3. Smoke-test from inside the workspace: `bwrap --unshare-user --unshare-pid --ro-bind / / echo ok`. If it still fails after the host fixes above, set `"enableWeakerNestedSandbox": true` in `~/.srt-settings.json` (srt's documented flag for Docker environments) rather than loosening the workspace container's own `seccomp`/`apparmor` profile — do not reach for `--privileged` or `--security-opt seccomp=unconfined` on the workspace container as a first fix, since that weakens the Rule 1 container boundary itself.

**Configuration** — version the template at `agent-host/srt-settings.json` in the repo; have the workspace startup script copy/symlink it to `~/.srt-settings.json` in the persistent home volume (M4) on first boot:

```json
{
  "network": {
    "allowedDomains": ["github.com", "*.github.com", "api.github.com", "copilot-proxy.githubusercontent.com"],
    "deniedDomains": []
  },
  "filesystem": {
    "denyRead": ["~/.ssh", "~/.aws", ".env", "~/.claude", "~/.copilot"],
    "allowWrite": [".", "/tmp"],
    "denyWrite": [".env", "**/secrets/**"]
  },
  "enableWeakerNestedSandbox": false
}
```

**`denyRead` must include the agent's own credential stores.** M4's persistent home places `~/.claude` and `~/.copilot` inside the same volume `srt` otherwise protects — without adding both here, a sandboxed `opencode` session could still read `pi`'s stored credentials (or vice versa), since read access is allowed by default except what's explicitly denied.

Adjust `network.allowedDomains` to the chosen backend provider's endpoints, and extend with MCP/lab-simulator endpoints once Phase 3's M11 exists.

**Wrap the harnesses** by default via shell alias:

```bash
alias opencode='srt opencode --'
alias pi='srt pi --'
```

### Agent Test

Create a deliberately failing unit test in a branch. Ask the agent (via `opencode` or `pi`, sandboxed):

```text
Investigate why the test fails.
Do not modify code.
Return:
- root cause
- affected file
- recommended fix
```

### Validation Milestone M9

The model must see repository context, identify the known failure, and not require manual copying of the entire repository into chat.

Run this test with **both** `opencode` and `pi` at least once, and record which one becomes the default harness for later milestones (M10's `gh-aw`, M11's agent-driven MCP calls). Additionally, confirm both harnesses run correctly through the `srt` sandbox wrapper (restrictions enforced, agent still functional against allowlisted endpoints).

### Manual E2E Test M9

1. Create fresh agent workspace (or worktree, per M5).
2. Authenticate the selected provider.
3. Intentionally break the sample project.
4. Ask the agent (`opencode` first, then `pi`) to diagnose it — both wrapped in `srt`.
5. Compare the diagnosis with the known problem.
6. Save transcript/evidence for each CLI.
7. Confirm the sandbox actually restricts the agent: attempt to read `~/.ssh/id_rsa` and to reach a non-allowlisted domain, and confirm both are blocked by `srt`.
8. Confirm cross-credential isolation: a sandboxed `opencode` session cannot read `pi`'s credential store (`~/.copilot`) and vice versa.

Record in `docs/milestone-reports/M9-agent.md`.
