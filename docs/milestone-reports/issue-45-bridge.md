# Issue #45 — Direction 4: cade-only reverse Unix-socket bridge

Closes the Issue #43 architectural blocker: `srt`'s `bwrap --unshare-net`
gives a sandboxed `opencode serve` process its own private network
namespace, making its TCP loopback port unreachable from the unsandboxed
`omnigent host` runner that needs to reach back into it for chat-turn
orchestration. No mocks, no dry runs — verified against real running
containers and a real omnigent web UI chat session.

- **Branch:** `issue-45-direction-4-bridge` (commits `a9e2a9d`, `f401e44`).
- **Environment:** local Coder server, `agent-workspace` template
  (`srt`-wrapped `opencode`/`pi`), throwaway workspaces created and
  deleted per verification pass.

## Problem

`srt opencode -- serve ...` (the sandboxed harness omnigent's
`opencode-native` runner launches) always applies `bwrap --unshare-net` on
Linux with no CLI flag/settings-file escape hatch — confirmed by checking
`srt --help` and its installed package's `linux-sandbox-utils.js`. This
gives the sandboxed process a private netns with only an outbound
HTTP/SOCKS proxy for its own traffic. Omnigent's supervisor needs the
opposite: an external, unsandboxed process reaching back *into* the
sandboxed harness's TCP loopback port. A genuine design mismatch between
`srt`'s all-or-nothing network isolation model and omnigent's
supervisor-reaches-into-harness architecture — not fixable from a Coder
template/startup-script alone via TCP.

## Design: Direction 4 — reverse Unix-socket bridge

Unix domain sockets are filesystem objects, not network endpoints, so a
socket file under a bind-mounted directory (e.g. `/tmp`, already shared
between the sandboxed and unsandboxed mount namespaces) crosses the
network-namespace boundary that a TCP port cannot. Implementation, both
added to the `agent-workspace` template's `startup_script`:

- **Inside the sandbox:** the `opencode` shim now runs `srt -c "socat
  UNIX-LISTEN:<sock>,fork,reuseaddr TCP:127.0.0.1:<port> & exec opencode
  serve ..."` — a `socat` relay listening on a Unix socket, forwarding to
  `opencode serve`'s real TCP port, both inside the same `bwrap` netns.
- **Outside the sandbox:** a watchdog process (idempotent, PID-file
  guarded) spawns a matching `socat TCP-LISTEN:<port>,fork,reuseaddr
  UNIX-CONNECT:<sock>` that bridges a real TCP port back to that same Unix
  socket, for the unsandboxed `omnigent host` runner to dial as if talking
  to a normal loopback service.

Full process chain confirmed live: shim → `srt -c "socat UNIX-LISTEN:...
& exec opencode serve ..."` → `bwrap --unshare-net` → inside: `socat` +
`opencode serve`; outside: watchdog-spawned `socat TCP-LISTEN`.

## Verification pass 1 (Step 3, isolated `docker exec`)

Exercised the bridge directly inside a throwaway container (not through a
live omnigent chat) to prove the mechanism itself before testing the full
stack. Found and fixed three real bugs in this pass:

1. **`srt-settings.json`'s `allowWrite` allowlist** was missing `~/.cache`
   and `~/.config` — `opencode serve` crashed with `EROFS` on startup
   without them. A long-running server process writes to more paths on
   startup than a one-shot interactive CLI session does; enumerate all of
   them, not just workspace/project paths.
2. **Watchdog start-idempotency check self-matched.** `pgrep -f
   'bridge-watchdog.sh'` matched the running `startup_script`'s own
   process, because Coder executes `startup_script` as one `sh -c "<script
   text>"` invocation — the script's own comments/heredoc text containing
   that literal string *is* part of the running process's command line.
   Fixed with a PID-file + `kill -0` check instead of a string-based
   `pgrep -f`.
3. **Stale socket reap logic was wrong.** `[ ! -e "$sock" ]` never fires
   for a dead Unix socket special file — the file is not automatically
   removed from disk once its listener process exits. Fixed by actively
   probing liveness (`socat -u OPEN:/dev/null UNIX-CONNECT:"$sock"`, which
   fails fast against a dead socket) instead of trusting mere file
   existence.

## Verification pass 2 (Step 4, real Stage B E2E via omnigent web UI)

Re-verified end to end through the real omnigent web UI, not an isolated
`docker exec`:

- A real chat turn drove `opencode serve` through the new bridge and
  completed successfully — the original blocker
  (`RuntimeError: opencode serve did not become ready:
  ConnectError('All connection attempts failed')`) is resolved.
- Adversarial checks (Issue #23 regression check) re-run via the real chat
  session: reading `~/.ssh/id_rsa` and writing `.env` were both denied —
  `denyRead`/`denyWrite` sandbox properties are not regressed by the
  bridge.
- Screenshots: `.playwright-mcp/issue45-stageb-successful-chat-turn.png`,
  `.playwright-mcp/issue45-stageb-adversarial-checks.png`.

## Known limitation (unmerged branch)

Since this branch isn't merged yet, both verification passes had to
manually overwrite `~/.srt-settings.json` inside each throwaway container:
the real `agent-workspace` `startup_script` clones `origin/main`, which
lacks this branch's fix. This limitation disappears once the branch
merges — it is a testing workaround, not a defect in the fix itself.

## Result

| Check | Result |
|---|---|
| Bridge mechanism (isolated `docker exec`) | **PASS** (after fixing 3 bugs above) |
| Full Stage B chat turn via real omnigent web UI | **PASS** |
| Issue #23 sandbox regression check (`denyRead`/`denyWrite`) | **PASS** |
| Cleanup (throwaway workspaces/containers) | **PASS** — all deleted after each pass |
