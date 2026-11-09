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
stall. The exact historical startup timeout remained unresolved at this
handoff. The corrective pass below distinguishes independently reproduced
defects from that unresolved historical sequence.

Acceptance remains **incomplete**: no successful Omnigent browser-streamed
session invoking native `search_docs`, writing a file, and demonstrating the
actual sandbox network denial in the same acceptance run. The bridge, PATH
shim, and watchdog remain in place; this issue does not establish that they can
be removed safely. Do not claim #146 acceptance or open a PR until that full
path passes.

## Issue #146 corrective implementation and separate review — 2026-11-08

**INCOMPLETE — do not merge or claim issue acceptance.** This pass made no
commit, push, or PR. It worked only in the existing issue worktree at
`ebb4b2d`; the coordinator's `main` was not edited. The version triple remains
Omnigent server/host **0.21.0**, OpenCode **2.0.32**, with **uv 0.9.5**.

### RCA corrections and bounded changes

The preceding three RCA chains identified independent, reproducible defects;
they did **not** establish the exact cause of the historical paired-MCP timeout.

1. A fresh `uv run` can synchronize/install packages inside SRT, where
   `files.pythonhosted.org` is denied. Both templates now provision the locked
   docs environment using trusted `uv sync --frozen` before host startup.
   Repository launches use `uv run --no-sync`; the global first-boot seed uses
   the provisioned Python directly. Blank checkouts omit the docs seed; a
   broken docs project stops startup. User-owned configs are preserved.
2. Native TUI and stdio MCP tool/policy calls need to cross a second network
   namespace boundary. The shared image launcher preserves the proven server
   UDS/watchdog path and adds narrowly scoped TUI and relay sockets. A plain
   relay-port forward would expose outside-runner shell/file/dispatch actions;
   the new relay forwards only policy evaluation and three context tools
   (`list_comments`, `sys_list_models`, `load_skill`). Other relay tools return
   an explicit error rather than executing outside SRT.
3. Global `/api/info` readiness is not location/plugin readiness. The launcher
   publishes its server socket only after authenticated, location-routed
   `/api/model` and required native MCP status checks, with a monotonic
   30-second bound. The existing unreachable lab-sim loopback MCP is not a
   required startup gate and is not claimed fixed.

**Explicit integration tradeoff:** installed v0.21.0 generates a policy plugin
that returns ALLOW on HTTP failure. It has no fail-closed switch. The launcher
therefore adjusts only that generated plugin's evaluation fallback, rejects
malformed verdicts, and refuses an unexpected source shape. It does not patch
installed dependency source or vendor an adapter framework. Review this
pinned-source coupling before accepting the change. Its socket permissions
are owner-only; SRT, network allowlists, and AppArmor were not disabled.

The obsolete dummy-provider credential write and its operator instructions
are removed. The installed `OpenCodeAuthSummary.ready` explicitly returns
`installed`; fresh tested workspaces had no dummy `auth.json` and reported the
native harness ready. Existing real credentials were not deleted.

### Runtime evidence and limitations

An earlier cold native browser turn in `i146-cold`, entered through the real
Coder Omnigent tile, invoked `tools["devenv-docs"].search_docs({query:"Node"})`
through OpenCode Code Mode and returned **20 hits**. It then used normal
`read`, `write`, `edit`, and `shell` tools. Independent disk inspection matched
`b'I146_NATIVE_COLD'` exactly (**16 bytes**, no newline). Native shell `curl`
returned **CONNECT 403 / exit 56**. Server PID 1089 and TUI PID 1286 had
network namespaces distinct from the workspace's namespace and both reported
`cade-bwrap-workspace (enforce)`.

The same browser session added Omnigent's real file/shell-approval policy.
Clicking **Approve** completed `printf I146_APPROVED` with that exact output.
Clicking **Reject** aborted the separate write command; independent inspection
confirmed `i146-denied.txt` was absent. Screenshot:
`.playwright-mcp/issue-146-approved-rejected.png` (local, ignored artifact).

After narrowing the relay, a fresh `i146-final` native browser turn completed
an actual **`omnigent_sys_list_models`** relay call (its response reported zero
available models; this is not proof of usable dispatch models). Native read,
write, and shell operations produced `b'I146_FINAL_BYTES'` (**16 bytes**) and
the same network denial. An actual **`omnigent_sys_os_shell`** call returned
`CADE denies outside-runner actions`; `i146-relay-escape.txt` remained absent.
That turn **failed docs acceptance**: `/api/mcp` reported docs **failed /
Request timed out**, while Omnigent was **connected**. Tool advertisement and
a submitted prompt containing `search_docs` were not counted as execution.

The agent-workspace host also registered with the correct versions and ran
native OpenCode, but its requested docs/file/command scenario did not finish
successfully. A direct, unsandboxed docs process subsequently returned no
initialize response within **15 seconds**. A separate import probe exceeded
**30 seconds**, with a five-second faulthandler trace in `_lzma` extension
loading. This distinguishes that observed failure from sandbox egress denial;
it does **not** diagnose its underlying cause or the historical paired timeout.
No protocol change, egress allowance, or blanket timeout increase was added.

Normal `omnigent host stop --server ... --daemon-only` stopped the targeted
daemon, but a subsequent background start failed to register within its
30-second bound. A later fresh `i146-verified` workspace provisioned deps but
did not register a selectable host. Browser reconnect plus a follow-up tool
call, and workspace/session restart recovery, remain unproven. The final
review added a required-MCP readiness gate and argument validation; these
last adjustments have regression evidence, not a new passing browser run.

| Acceptance | Result | Evidence boundary |
|---|---|---|
| Matching supported pins | PASS | Live server/host 0.21.0 and CLI 2.0.32 |
| Docker native browser stream | PASS | Real tile, model stream, persisted native tool messages |
| Repeatable final cold docs MCP | FAIL | Subsequent native docs connection timed out |
| Native file bytes/commands/network denial | PASS | 16-byte independent comparisons; CONNECT 403 / exit 56 |
| Explicit approval and rejection | PASS | Real UI decisions and aborted-write absence in earlier turn |
| Restricted outside relay | PASS | Actual context call; actual outside-shell rejection and no file |
| Final agent-workspace acceptance scenario | FAIL | Requested native docs scenario did not complete |
| Browser reconnect + follow-up | UNKNOWN | No successful follow-up acceptance call after reconnect |
| Host restart recovery | FAIL | Registration timeout after targeted daemon restart |
| Workspace/session restart persistence | UNKNOWN | Not completed; source layout alone is not proof |
| Native TUI prompt round trip | UNKNOWN | Process/namespace attested; no independent keyboard prompt test |
| #134 protected-file regression | UNKNOWN | Explicitly separate, not changed or claimed fixed |

### Reproduction and regression gate

Dirty-tree build guards remain intact. Local verification used their direct
Docker build equivalents, not an unauthorized commit/push:

```bash
docker buildx build -f coder/Dockerfile --build-context agent-host=agent-host \
  -t cade/coder-workspace:latest -t cade/coder-workspace:issue-146 --load coder
docker buildx build -f coder/agent-workspace/Dockerfile \
  -t cade/agent-workspace:issue-146 --load coder/agent-workspace
WORKSPACE_IMAGE=cade/coder-workspace:issue-146 bash tests/coder-omnigent-launch.sh
uvx --from ruff ruff check coder/omnigent tests/coder-omnigent-launch.py
uvx --from ruff ruff format --check coder/omnigent tests/coder-omnigent-launch.py
docker cp -L coder:/usr/local/bin/terraform /tmp/opencode/terraform-146
/tmp/opencode/terraform-146 fmt -check coder/templates/docker-workspace coder/templates/agent-workspace
bash -n tests/coder-omnigent-launch.sh
git diff --check
```

Two disposable templates (`issue-146-docker`, `issue-146-agent`) were pushed to
the isolated Coder deployment and used for real creates. Their native
provisioning consumed the changed image/template. The checkout cloned remote
CADE; the reviewed repository `opencode.jsonc` was copied into the disposable
checkout before native launch, without manually synchronizing or warming MCP.
This explicitly distinguishes local verification from publication on remote
`main`. The regression gate uses the pinned built implementation, real
generated Omnigent plugin source, actual HTTP/UDS traffic, and extracted
production startup blocks, including invalid input, unavailable relay,
malformed verdict, failed MCP, broken docs-project, and blank-checkout cases.

### Separate review and cleanup

Final local validation: **6/6 regression tests passed in 6.775 seconds**;
Ruff check, Ruff format check, Terraform format check, shell syntax, and
`git diff --check` passed. The final Docker base image built successfully as
`sha256:38ce345de1ac6caf3969b158d110a7c972f7c84823091b75d09852f9adcd4161`.
An isolated `--rm --network none` smoke test using the template's unchanged
seccomp/AppArmor/systempaths settings ran the final launcher under SRT and
returned `opencode v2.0.32`, proving the private namespace entry guard works
on the real sandbox path. This is not a replacement for native browser acceptance.
The final agent image rebuild **failed** because the existing Boundary 0.10.0
release download returned **GitHub HTTP 504**. Its retained test image
`sha256:c6692775e20d667a325b0d97f68702bacb446bd9cc4f209708c353555d636a48`
is the earlier artifact used in runtime tests, **not** the final reviewed
launcher. No installer, version pin, or security guard was bypassed to hide
this build failure.

The separate local review found three correctness gaps: keyword `serve` could
misclassify a prompt, a model-ready response could precede a failed docs
connection, and the private inside entry needed a namespace precondition.
Argument validation, the required-MCP startup gate, and parent/child namespace
attestation address those gaps. Independent coordinator review remains required; the recommendation
is **BLOCK acceptance**, not approval, because the native cold/restart gate fails.

Three created Omnigent sessions were deleted via the real API (HTTP 200 each):
`7548d9b9b2e34bb8a3c2e43459cb7057`, `9c3d0baabf624e768bbb93569334e635`,
`ce224c1d96984d5380321a91fc2cb057`. Four ordinary Coder deletes, then four
documented `--orphan` deletes, each failed during provider installation:
GitHub checksum requests returned **HTTP 504**. Template deletion was then
rejected because workspace records remained. Exact disposable containers were
removed to stop their processes; the following **test-only** home volumes and
failed Coder records are retained for a normal cleanup retry when registry
access works:

| Failed Coder workspace | Retained test home volume |
|---|---|
| `cade-admin/i146-cold` | `coder-cb6b0485-e8dd-414e-9af5-cc0124523e0d-home` |
| `cade-admin/i146-final` | `coder-5e3aa80e-f22b-4118-9bcd-8f814a010981-home` |
| `cade-admin/i146-agent` | `coder-9d1a4a9c-f3f5-495d-99ad-31ab33586fbf-home` |
| `cade-admin/i146-verified` | `coder-1ab1ae3a-f697-49a0-b3b4-cc7abdf145c2-home` |

Three new offline host records also remain; the installed API has no host-delete
route. The pre-existing RCA residual host was not modified. No direct DB edit,
historical-volume deletion, host config change, `sudo`, privileged container,
or interruption of unrelated services was used. The protected pre-upgrade SQL
dump remains outside Git and was not opened. Test image tags and sanitized
local command logs are retained for coordinator review.

## Issue #146 cancelled-work recovery and verified handoff

**INCOMPLETE — separate adversarial review must not approve the acceptance gate.**
The prior dirty work was investigated and preserved; no commit, push, PR,
delegation, coordinator edit or change to the supported pins was made.

### Findings and minimal additional fix

- Replaying `WORKSPACE_IMAGE=cade/coder-workspace:issue-146 bash
  tests/coder-omnigent-launch.sh` against the retained image failed **1/6**:
  list-valued relay tool names raised `TypeError`. The worktree contained the
  input-validation fix, but the previous report's described final image did not.
  Image IDs alone therefore did not establish source/artifact consistency.
- Rebuilt the base from the preserved sources. Added only an idempotence fix
  to `fail_closed()`: accept the exact hash of its corrected evaluation function
  on repeat launch, while continuing to reject any other source. Its regression
  checks repeated correction leaves bytes unchanged and no ALLOW fallback remains.
- Final base: `sha256:686cab43638f866cf2566d9fcc481feeebe83f7bc43fce36ce76c6846b92be2e`.
  Final local agent integration image:
  `sha256:426c8315c14e336490d662bca750796ad441a9a35afa3ef9926bbfe4b7a3ff68`.
  Both contain the corrected launcher; each passed **6/6** regressions.
  Final recheck: **5.868 seconds / 7.191 seconds**, Ruff lint/format,
  template format, whole-startup shell syntax and `git diff --check` passed.

### Native evidence versus final gate

The fresh `i146-resume-docker` was entered through its real Coder Omnigent
tile. Its first native terminal startup failed; a subsequent native execution
in the same conversation succeeded. Independent authenticated native API
inspection, not the agent's prose, recorded:

- `execute` called native `devenv-docs.search_docs`, query `Node`, count **20**;
  docs and Omnigent MCP statuses were `connected`.
- Native `read`, `write` and `shell` completed; independent bytes were exactly
  `b'I146_RESUME_COLD'` (16 bytes). Command output was `I146_RESUME_COMMAND`.
  `curl` reported **CONNECT 403 / exit 56**.
- `omnigent_sys_list_models` completed; its no-provider result is not usable
  dispatch acceptance. `omnigent_sys_os_shell` returned an actual tool error,
  `CADE denies outside-runner actions`; the escape file was absent.
- Server PID **1600** used `net:[4026534120]`; native TUI PID **1867** used
  `net:[4026534178]`; workspace namespace was `net:[4026533989]`.
  Both native processes reported `cade-bwrap-workspace (enforce)`.
- The real approval policy asked for `printf I146_RESUME_APPROVED`; clicking
  **Approve** completed it. Clicking **Reject** aborted the separate scratch-write
  command, and independent inspection found `i146-resume-denied.txt` absent.
- Browser reload/reconnect followed by an approved native read and native
  docs search completed; its response again reported 20 hits and the scratch bytes.

These turns preceded the final idempotence rebuild. Final-image fresh workspaces
`i146-gate-docker` and `i146-gate-agent` provisioned dependencies and registered,
but did **not** pass native acceptance: the host rejected the project-directory
Docker launch as `opencode-native is not configured`, and the agent UI advertised
OpenCode unavailable. A probe using the agent daemon's actual environment returned
`opencode v2.0.32` in **6.51 seconds** with the SRT shim present in PATH. Why the
readiness verdict disagrees is **not diagnosed**. No timeout increase, dummy
credential or readiness override was added.

A direct `docker exec omnigent host ...` restart omitted Coder's injected
environment and produced native processes in the workspace network namespace.
That attempt is **invalid and excluded** from acceptance. The owned host/session
was stopped, then real `coder stop`/`coder start` succeeded. A subsequent valid
sandboxed native follow-up and byte comparison were not completed before cleanup.
The historical paired MCP timeout remains undiagnosed; an observed slow docs
import (18.8 seconds outside SRT) does not establish its root cause.

| Check | Result | Evidence boundary |
|---|---|---|
| Supported pins / final base build | PASS | Live server 0.21.0, host 0.21.0, CLI 2.0.32 |
| Final-image regression / lint / format / syntax | PASS | 6/6 per image; repeated plugin correction tested |
| Docker native docs/file/command/network tools | PASS | Native API traces and independent bytes before final rebuild |
| Actual approval / rejection | PASS | Real policy/UI decisions and denied-file absence |
| Reconnect plus real native follow-up | PASS | Native docs search and approved read before final rebuild |
| Repeatable final cold Docker native turn | FAIL | Host rejected native harness as not configured |
| Final agent-workspace native scenario | FAIL | UI advertised harness unavailable; no passing turn |
| Canonical agent image build | FAIL | Pinned Boundary release URL returned GitHub HTTP 504 |
| Normal restart plus valid native follow-up | UNKNOWN | Coder lifecycle succeeded; no valid follow-up gate |
| Native relay unavailable, safe handling | UNKNOWN | Generated-plugin/HTTP regression passes; no native browser outage test |
| Separate TUI keyboard / #134 protected-file case | UNKNOWN | Not tested / separate scope |

### Reproduction constraints and retained evidence

Direct base build, the two `WORKSPACE_IMAGE=... bash tests/coder-omnigent-launch.sh`
runs, Ruff check/format, `terraform fmt -check`, extracted whole-startup
`bash -n`, and `git diff --check` were used without bypassing dirty-tree guards.
Canonical agent build failed again. For local integration only, the exact pinned
Boundary asset fetched with `?download=1` returned 200 and matched its published
SHA-256 `529431a04be6b12b69b10045553c642b1e10f7cb1fd55f63ea7daa5166d0d8b1`.
An ephemeral Dockerfile layered those verified v0.10.0 bytes onto the final base;
this is **not** a claim that the repository's canonical agent build passed.

Disposable template startup injected the exact worktree `opencode.jsonc` into
the cloned public checkout **before trusted provisioning**, not via manual MCP
warming after create. Other repository content came from remote CADE. This
distinguishes tested local inputs from unpublished changes. Terraform release
checksum requests also returned cached 504; local lockfiles computed from
Coder's previously installed provider cache allowed scoped provisioning/cleanup.
No host Terraform config, allowlist, installed dependency source or confinement
setting was changed.

Local command/evidence logs are under `/tmp/opencode/`:
`issue-146-resume-final-image-build.log`, `issue-146-resume-final-agent-build.log`,
`issue-146-resume-agent-image-build.log` (canonical failure),
`issue-146-resume-docker-evidence.log`, `issue-146-resume-docker-policy-evidence.log`,
`issue-146-resume-workspace-{stop,start}.log`, and
`issue-146-{resume,gate}-create-{docker,agent}.log`.

### Cleanup and credential incident

The browser tool echoed a private Coder login script containing its test session
token. That token was immediately revoked via Coder's API; a request with the old
token was verified **HTTP 401**, and the isolated CLI session was replaced
privately. The credential-bearing script was removed. Later browser code consumed
credentials through a private runtime helper without embedding them in source.

Three created Omnigent conversations were deleted (HTTP 200 each). Seven remaining
issue-owned Coder records were deleted using their same-template active locked
version; `coder list --all` then reported **No workspaces found**. Four earlier
failed-run home volumes were independently checked for zero container references
and removed by exact documented name. The four newly-created home volumes were
absent after normal cleanup: an explicit check found **8/8 documented test home
volumes absent**, **0 issue test containers**, and the helper PID absent.
Four issue-only templates were deleted. Offline host
records remain; there is no supported host-delete route, and the known RCA host
was not edited. The private helper and credential parameter files were removed;
test image tags and non-secret reproduction artifacts remain for review. The
protected pre-upgrade SQL dump was preserved and not opened.

## Issue #146 adversarial-review corrections — current handoff

**INCOMPLETE / BLOCK acceptance. Native repeat verified 2026-11-08T15:55:50Z.**
The cancelled diagnosis left a newer, unaccepted phased-readiness experiment in
the worktree. Its failures supersede the earlier image's agent PASS as a claim
about current code. No implementation was edited or discarded during recovery;
no commit, push, PR, delegation, main-source edit, dependency patch, database edit
or confinement-setting change was made. The earlier evidence below is historical.

### Cancelled-diagnosis recovery and fresh-context review

- Ownership was verified from Coder workspace IDs, Docker labels and image IDs
  before cleanup. Retained `i146-phase-docker2` and `i146-phase-agent` ran the
  phase-v2 images, not the previously accepted artifacts listed below.
- Current launch SHA-256: `cd8fbdd6edb83fd72cec265b3d5ba05a075146054873aca2bd33fa068c995a59`.
  Current Docker/agent image IDs:
  `7604f17ff77ebc76da710a6991d7d28c3d5625edef16a8cb855b2935249ed596` /
  `a06192a8de167bd381e53716712a4426d5f667cb1d02ace3f20d97e19bb80e86`.
  Relay/seed hashes are unchanged. `/tmp/opencode/issue-146-recovery-manifest.json`
  records the six source/test hashes and the two owned home volumes.
- `tests/coder-omnigent-readiness.py` is a retained two-test experiment, not an
  unexplained file to remove. Current `wait_location` activates `/api/model`
  once after success, grants MCP its separate 30-second phase, and publishes
  the UDS when required catalog entries are present, even if still `pending`.
  This changes the prior readiness contract; it is not a demonstrated fix.
- Fresh source/image consistency regressions pass **13/13 per image**:
  `WORKSPACE_IMAGE=cade/coder-workspace:issue-146-phase-v2 bash tests/coder-omnigent-launch.sh`
  (**19.100s**) and the equivalent agent image (**18.797s**). Logs:
  `/tmp/opencode/issue-146-recovery-tests-{base,agent}.log`.
  Ruff check/format over the three sources and two Python fixtures, shell syntax,
  and `git diff --check` pass. These tests do not prove native acceptance.
- Retained `issue-146-phase-v2-native-failure.json` shows agent event-stream
  `RemoteProtocolError`/`ConnectError`, Docker model-discovery transport errors,
  no scratch marker in either workspace, and Docker registration's 30-second
  failure. These are retained observations, not a fresh paired reproduction.
- Retained Docker trace `issue-146-diff-fresh-docker.json` reaches a real catalog:
  Omnigent `connected`, docs `pending`, lab-sim `failed`, followed by deadline
  failure. A separate instrumented docs trace records initialize, tools/list
  and tools/call responses. The experiments differ; neither establishes causal
  necessity of lab-sim, stdio transport, or socket publication for the baseline
  Docker failure. Historical paired MCP-timeout RCA remains **UNKNOWN**.
- Pinned upstream source confirms directory-header decoding in
  `packages/server/src/location.ts` and asynchronous initial connections in
  `packages/core/src/mcp/index.ts` at tag `v2.0.32`. This supports separating
  activation stages, but does not prove an outside-bridge activation cycle.
  No timeout increase, dummy credential, fixed sleep or policy weakening was used.
- **Recovery incident / authenticated-gate blocker:** an unfiltered Coder JSON
  listing exposed the disposable Omnigent account password in tool output.
  The recovery helper rotated it through `POST /auth/users/me/password`, but
  incorrectly parsed the successful **204** as JSON before saving its generated
  replacement. The old password now returns **401**; the replacement was not
  retained. Other account sessions/CLI logins were revoked by the supported API.
  This historical access blocker is resolved: the coordinator performed the
  explicitly authorized installed-account-store password reset, saving the
  replacement privately before mutation. Fresh supported `/auth/login` returned
  **200** during this repeat. The replacement credential remains private and was
  neither rotated again nor deleted. No authentication bypass was used.

Fresh-context review verdict: **BLOCK**. Do not promote the phased experiment
or reuse the historical agent PASS for current code. Account access is restored;
native acceptance and the causal startup diagnosis are still incomplete.

### Authenticated repeat on the unchanged phase-v2 artifacts

- Fresh actual login returned **200**; two initial fresh hosts registered online.
  Initial Docker and agent native sessions failed terminal startup. No launcher,
  relay, seed, template source, version pin or confinement setting was changed.
- A temporary diagnostic launcher in the owned Docker container recorded the
  real `/home/coder/project` timeline: `/api/model` returned **200 at 13.337s**;
  required docs and Omnigent MCP entries were pending at **13.347s**. Omnigent
  subsequently connected; docs returned **Request timed out at 41.511s**.
  Native log timestamps independently record the docs startup timeout.
- A wire wrapper preserving the original `uv run --no-sync python -m` command
  received the native **initialize** request but recorded no response. Its
  import-time control was still importing MCP modules before the deadline.
  Later direct/SRT import controls took **6.066/6.832s** on Docker and
  **8.728/6.071s** on agent. A later non-cold SDK trace answered initialize and
  tools/list at **9.359/9.390s**. These changed conditions are not necessity or
  sufficiency proof; the cold startup root cause remains **UNKNOWN**.
- Diagnostic workspaces were deleted before two sequential fresh, uninstrumented
  repeats. Exact launcher/relay/seed hashes matched the current source in each.
  Both actual Coder dashboard tiles opened the authenticated Omnigent browser.
  Docker conversation `5520a2828702413f89a6c6de6601b5cc` reached the model endpoint;
  its actual server had a separate network namespace and enforcing AppArmor.
  Docs/Omnigent catalogs were connected, but this is **not a successful MCP call**.
  Two real browser prompts, selecting catalog models `opencode/big-pickle` and
  `opencode/deepseek-v4.1-flash-free`, both returned **Free usage limit reached**.
  No credential import, paid subscription or fake model was used to evade it.
- Sequential cold agent conversation `85a968284b9a42888d20e8d947b0c80d` again failed
  native terminal startup; its real native log records docs **Request timed out**.
  No successful inference, native docs search, bytes, approval/rejection, pending
  approval relay-loss safety or restart acceptance is claimed for current code.
- Fresh consistency/regression runs passed **13/13 per image**, Docker **20.739s**
  and agent **27.773s**. These do not override the failed native acceptance.
  Sanitized repeat manifest, inner logs, SDK/wire controls and cold-probe evidence
  are under `/tmp/opencode/issue-146-repeat-*`. Runtime instrumentation stayed
  outside Git and disappeared with its owned containers; no speculative fix was
  added, and no timeout budget was increased.

### Review-fix matrix

| Review finding | Correction | Evidence |
|---|---|---|
| Stock persisted-home seed lacks docs | Tiny shared `seed.py` upgrades only the unchanged model-only CADE JSON seed; fresh homes get the same entry. Customized JSON/JSONC, alternate `opencode.json`, and credentials remain operator-managed. | Real installed `maybe_merge_user_provider_config` regression checks fresh and persisted stock homes produce both MCP names; customized model/JSONC/provider settings remain byte-identical. Manual opt-in entry is documented in `/docs/ai-coder.md`. |
| Missing docs catalog accepted as ready | Required enabled MCP names come from the generated per-session config, not the returned catalog. Presence and `connected` status are required. | Actual HTTP tests: missing docs times out, failed docs rejects, connected docs succeeds, generated blank-checkout config requires only Omnigent. |
| Stale image can pass mounted tests | Shell gate compares repository/image SHA-256 for launcher, relay and seed before importing image implementation. | Retained image was rejected with `Stale workspace image: omnigent-launch.py differs from repository`; the final two images pass the consistency gate. |
| Requested login/host failures suppressed | Removed login/host `|| true` and the executable-presence skip. Only password absence deliberately skips registration. | Real HTTP 503 login regression stops both extracted startup blocks; shell launch-failure fixture stops downstream execution; blank password skips. A real failed Docker registration now surfaces as failed Coder startup, not a healthy integration. |
| Required bridge children unsupervised | Probe real TCP/UDS listeners, monitor required subprocesses during readiness and execution, and terminate owned process groups during cleanup. | Real socat bind failure and post-start death regressions; real relay-death subprocess regression proves its owner is terminated. Native browser outage evidence below is separate from generated-plugin fail-closed tests. |

### Readiness root cause: reproduced, not inferred

The installed 0.21.0 `harness_readiness._binary_availability_reason` calls
`harness_cli_installed(..., timeout=10.0)`. In the real Docker daemon context:

```text
cwd=/home/coder; resolved=/home/coder/.omnigent-bin/opencode
mode=srt; passthrough=OMNIGENT_SANDBOX_MODE,PATH
argv=[resolved, --version]; budget=10.0; elapsed=10.218; TimeoutExpired
launch-verdict=False
budget=10.0; elapsed=10.139; TimeoutExpired; picker=version-too-low
same command; budget=30; elapsed=10.080; exit=0; version=v2.0.32
```

The successful 30-second probe does not contradict the failed 10-second gate.
The exact non-agent `--version` request now invokes the real pinned CLI directly,
with no fake version output or readiness override. Any extra argument still
takes the SRT path; server, TUI, prompts and tools remain confined. Omnigent's
probe budgets are unchanged. Final actual daemon probes returned `True` for
launch and picker: Docker **0.562s**, restarted agent **0.574s**. The installed
package source was inspected, not merely the upstream default branch.

### Historical accepted-agent artifacts and commands

| Artifact | Verified SHA-256 / image ID |
|---|---|
| Docker image | `bbdebd21794e1f40cdf52cec55935bf96bfe6c8a8d285b674ef8c65ccce0263a` |
| Agent image | `2b8cd497310536a7a062af2d5c69da3fa867b615b565a5c2a0f6ebb3ba89d586` |
| `coder/omnigent/launch.py` | `40f6641c3268a2f41bbb5fe6a4f9239513b886ae398993cf1b21cb4c46c0a6dd` |
| `coder/omnigent/relay.py` | `dbc3130009b0dd0370e36c83beebf71b9542fb93e94e18ad22f1eef0fee22e9e` |
| `coder/omnigent/seed.py` | `8c03fc772e0776cf4b2f1dd17562dbc13ce6d0c29cd480fac3925dfdbcb6b08d` |
| `tests/coder-omnigent-launch.py` | `62d5b68300d2e5104cdce2b116c3aeacddb456f64e2957d557e9826ee681c94a` |
| `tests/coder-omnigent-launch.sh` | `c5aec1d883affd5441c9525235993f8e3dc9ffb587549fb2de2ca3b30bfbd3bb` |

The direct build equivalents shown above preserved the dirty-tree guards.
The canonical agent Dockerfile's unchanged Boundary URL first returned 504;
a bounded retry of the **same recipe** succeeded. Final canonical builds pass,
with `boundary --version` returning **v0.10.0**; no query-string/fallback
Dockerfile was used for these final artifacts. Live server/host/CLI are
**0.21.0 / 0.21.0 / 2.0.32**, and the server reports healthy.

```bash
WORKSPACE_IMAGE=cade/coder-workspace:issue-146 bash tests/coder-omnigent-launch.sh
# 11/11, 24.551s on final repeat
WORKSPACE_IMAGE=cade/agent-workspace:issue-146 bash tests/coder-omnigent-launch.sh
# 11/11, 13.380s on final repeat
uvx --from ruff ruff check coder/omnigent tests/coder-omnigent-launch.py
uvx --from ruff ruff format --check coder/omnigent tests/coder-omnigent-launch.py
/tmp/opencode/terraform-146 fmt -check coder/templates/docker-workspace coder/templates/agent-workspace
bash -n tests/coder-omnigent-launch.sh
git diff --check
```

Configured lint, format, Terraform format, extracted whole-startup shell syntax,
and whitespace gates passed. A separate warning-level quality-drift probe with
`ruff check --select C901` found `wait_location=11`, `run=20`; it is **not** a
passing complexity check. Source/test sizes are **315/118/29** and **493** lines;
the test/source ratio is below 2:1. Scoped quality-gate scores (runtime, test size,
source size, complexity, branch coverage, mutation) are **2/2/2/0/0/0**; no broad
CI/coverage/mutation framework was added to this integration fix.

### Historical native evidence and unresolved baseline blocker

Disposable templates injected the exact dirty `opencode.jsonc` before trusted
provisioning into the remote checkout. They did not pretend remote `main`
contained this work or manually synchronize MCP packages after startup.

Final agent conversation `f494e9304acf493a9347e366a562b355`:

- Native `execute` called docs MCP for `Node`; **20 hits**, also confirmed by
  the real streamed browser response. Native read/write/shell completed;
  independent bytes were **`b'I146_ACCEPT_AGENT'`**, 17 bytes without newline.
- Native curl returned **CONNECT 403 / exit 56**. Real `sys_list_models`
  completed; outside `sys_os_shell` returned `CADE denies outside-runner actions`,
  and the escape file was absent. No-provider dispatch is not inference proof.
- The real session policy asked for the shell command. Clicking **Approve**
  completed `I146_ACCEPT_APPROVED`; clicking **Reject** aborted the separate
  write, and the rejected file was absent. A model-generated question was not
  counted as policy approval.
- Browser reload followed by native read and docs search returned the same
  bytes and 20 hits.
- With an actual scratch-write approval pending, killed only required relay
  PID **2106**, then clicked **Approve**. Native servers/relays remaining were
  **0/0**; no outage file existed. UI reported permission-reply failure rather
  than executing. This proves safe required-relay process loss, not every
  possible upstream policy-backend failure.
- Real `coder stop cade-admin/i146-accept-agent --yes` and `coder start ... --yes`
  succeeded. Same browser conversation then performed native read, docs search
  and `I146_AFTER_CODER_RESTART`; independent bytes remained unchanged.
  Restarted daemon PATH retained the shim through its real environment filters.
  Workspace namespace **4026533992**, server PID **432** namespace **4026534054**,
  TUI PID **737** namespace **4026534179**; both native processes reported
  **`cade-bwrap-workspace (enforce)`**. A final native read also completed after
  entering through the actual agent dashboard tile.

Ephemeral native processes were replaced. Remote conversation recovery and
home-file persistence are proven; native database/session-ID continuity was not
independently established. Standalone TUI keyboard testing and #134 remain separate.
Screenshot: `/.playwright-mcp/issue-146-agent-restart.png` (**91,792 bytes**).

**Docker remains blocked**, including the correctly selected
`/home/coder/project` conversation `dc8fb5ac12a547c6abae3efab64165e9`.
Installed `OpenCodeNativeServer._wait_until_ready` exhausts its **60 polls**
with **0.5s delay** and per-request connect timeout **2s**, reporting
`opencode serve did not become ready: ConnectError(...)`. The CADE socket is
published only after authenticated location/MCP activation. Upstream stderr
diagnostics show the pinned policy plugin loading; native logs show lab-sim
connection refusal, but **neither proves why required local activation stalls**.
No timeout increase, dummy credential, policy bypass or egress change was made.
The older paired MCP-timeout root cause is still independently **unknown**.

Docker registration also hit the installed CLI's separate **30s** grace. Its
host capability initialization has a **15s** fallback and cold import overhead;
logs show the fallback and later SIGTERM, not a proven causal fix. Requested
failure is now exposed. Diagnostic recovery used Coder SSH with an explicit shim
PATH; an initial SSH invocation lacked that prefix, so its owned host was stopped
before any native prompt and excluded. No bare `docker exec` daemon restart was
used. Diagnostic stderr capture was confined to an owned disposable template.

| Acceptance gate | Current result |
|---|---|
| Matching published pins / canonical images / source consistency | PASS |
| Final regression tests / configured lint / format / syntax | PASS |
| Earlier agent image native docs/files/commands/network/context-denial | Historical PASS; current phase-v2 FAIL |
| Earlier agent image approval/rejection/reconnect | Historical PASS; current phase-v2 UNKNOWN |
| Earlier agent image required-relay outage safety | Historical PASS; current phase-v2 UNKNOWN |
| Earlier agent image normal Coder restart + bytes + native follow-up | Historical PASS; current phase-v2 UNKNOWN |
| Repeatable cold Docker native turn | FAIL: fresh terminal/model path reached; two provider quota rejections, no successful turn |
| Current Docker restart + successful native follow-up | UNKNOWN |
| Authenticated recovery / conversation cleanup | PASS: fresh login 200; supported API enumeration returns 0 sessions, has_more=false |
| Historical paired MCP-timeout RCA / standalone keyboard / #134 | UNKNOWN / UNKNOWN / separate scope |

### Cleanup and retained evidence

Historical cleanup: **5/5 created conversations** deleted through the API (200 each); **6/6 created
workspaces** normally deleted; **2/2 created templates** deleted. Coder reported
`No workspaces found`; **6/6 new home volumes absent**, **0 test containers**,
helper PID absent, **8 browser tabs closed**. Private parameter files/helper were
removed; the new browser account session was logged out (204). Offline host
records remain because the supported API has no deletion route. No DB edit,
historical-volume removal, host config change or unrelated service interruption.
Protected SQL metadata remains **28,546 bytes / 0600**, and the dump was not opened.

Recovery cleanup: **2/2 retained workspaces** and **2/2 retained templates** deleted
normally through Coder (exit 0 each); **2/2 owned containers** and **2/2 owned home
volumes** independently absent. Coder lists **0 workspaces**. Verified login-helper
PID **2868881** was terminated by exact PID and is absent; its retained browser tab
was closed, and its script/PID file and two obsolete private parameter files were
removed. Phased sources, fixtures, images and sanitized diagnostic artifacts
remain for review. The later authenticated repeat enumerated exactly **1 retained
conversation**, `e473d7da04f1483e99e62d527619b51d`, and deleted it through the supported
API. Offline host records were not edited.

Authenticated-repeat cleanup: **10/10 new conversations plus 1/1 retained
conversation** deleted; API enumeration returned **0**, `has_more=false`.
**4/4 created workspaces**, **2/2 template names**, and **4/4 owned home volumes**
were normally deleted; independent Docker checks found **0 owned containers**
and **0 owned home volumes**. Login helper was stopped by verified exact PID and
its script/PID file and provisioning helper were removed. Parameter files were
removed immediately after use. Two owned popup tabs were closed, the owned
landing tab cleared, and the two browser account sessions logged out (**204/204**).
Recovered account credential remains **0600** for continued operator access.
Protected unopened SQL dump remains **28,546 bytes / 0600**. No commit, push, PR,
further delegation, historical-volume removal or unrelated service interruption.

Sanitized retained artifacts under `/tmp/opencode/`:
`issue-146-review-manifest.json`, `issue-146-review-home-manifest.json`,
`issue-146-review-tests-{base,agent}.log`,
`issue-146-review-probe-after-turn.log`,
`issue-146-review-accept2-probe-docker.log`,
`issue-146-review-agent-before-outage.log`,
`issue-146-review-agent-after-outage.log`,
`issue-146-review-agent-restart-{probe,evidence}.log`, and the
`issue-146-review-{accepted-base-build,accepted-agent-build,agent-stop,agent-start}.log`
command records. Coordinator adversarial re-review is still required; this is
**not** authorization to close #146 or open a PR.
