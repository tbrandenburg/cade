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

## OpenCode 2 modernization re-check (Issue #146)

Omnigent v0.21.0 is the supported replacement for the former v0.11.0
server/host pair. Its release notes require OpenCode 2.0.18 through 2.0.x
and its official install documentation pins `@opencode/cli@2.0.32`. In a
fresh Coder `docker-workspace`, the matching host registered and reported
connected under v0.21.0; the installed CLI reported `opencode v2.0.32`.
An actual no-key `srt /usr/bin/opencode run` returned the requested response
from the documented `big-pickle` model. Sandboxed requests to an
unallowlisted network destination and `/etc/shadow` were denied, and the
workspace retained the enforcing `cade-bwrap-workspace` AppArmor profile.

The initial modernization pass did not exercise Omnigent web chat. A later
real browser chat through the Omnigent tile verified streamed completion,
writing an exact scratch-file marker, and denial of `curl https://example.com`
(CONNECT tunnel 403, exit 56). Process inspection confirmed the native
OpenCode servers were launched through the shim, each with a distinct network
namespace and the enforcing `cade-bwrap-workspace` AppArmor profile.

That pass exposed an MCP acceptance gap: the generated per-session config
contained the Omnigent bridge but no native user MCP servers, and the chat
could not discover `search_docs`. A manually launched JSON-RPC shim was used
in that investigation and is **not** native MCP acceptance evidence. Issue
#146 therefore seeds `devenv-docs` in the first-boot global OpenCode config
and installs pinned `uv` in the workspace image. Omnigent v0.21.0's
`maybe_merge_user_provider_config` reads the user's global OpenCode config
and merges its MCP entries into the generated per-session config; synthesized
entries take precedence. The existing remote `devenv-lab-sim` endpoint is
not seeded because its loopback URL is not reachable from the sandbox.

The native MCP check now has two distinct results. First, a direct OpenCode 2
process inside the enforced sandbox, in the fresh `oc2chat5` workspace,
successfully invoked the configured `devenv-docs` MCP `search_docs` tool via
OpenCode's normal tool API (Node query: 20 hits; architecture query: 14,787
characters). It used the repository `opencode.jsonc` and required no `uv` shim
or hand-written JSON-RPC. This proves the server, workspace config, and SRT
compatibility work in that direct-CLI path.

It does **not** prove the Omnigent browser-session path. A fresh Omnigent
v0.21.0 session did generate an XDG config containing `devenv-docs` and
`omnigent`, but OpenCode logged MCP connect request timeouts for both servers;
the app-server API returned `503 Location plugins did not finish activating`
and the chat ended in a read timeout. The configured absolute `cwd` was also
tested and did not resolve this. Omnigent v0.21.0 source confirms that
`maybe_merge_user_provider_config` reads the user's global config, merges user
MCP entries with synthesized entries taking precedence, and that orchestration
does so before writing the per-session config and starting the OpenCode server
(`omnigent/harnesses/opencode_native/provider.py:927-988`,
`omnigent/runner/native/orchestration.py:1948-1995`). That merge explains why
the entry appears, but does not establish why both configured MCP connections
stall. Root cause of the Omnigent startup timeout remains unresolved; no
product workaround is justified by the current evidence.

Acceptance remains **incomplete**: no successful Omnigent browser-streamed
session invoking native `search_docs`, writing a file, and demonstrating the
actual sandbox network denial in the same acceptance run. The bridge, PATH
shim, and watchdog remain in place; this issue does not establish that they can
be removed safely. Do not claim #146 acceptance or open a PR until that full
path passes.
