# M4 VS Code Agent Host + AHP — Milestone Report

## Current status — automated infrastructure verified; human acceptance pending

**Issue [#132](https://github.com/tbrandenburg/cade/issues/132) stays open.**
The AppArmor startup blocker was resolved by human profile loading, not a security
bypass. Real local and SSH-forwarded authenticated discovery subsequently passed.
The final coordinator E2E through corrected public launchers passed at
**2026-10-15T08:44:58Z**. Mandatory HUMAN fresh-workspace acceptance remains
pending. This is not M4 session-durability completion.

Runtime evidence below was captured on 2026-10-15: local proof through
`07:05:09Z`, remote proof/cleanup through `07:22:39Z`; focused corrected-launcher
checks at `07:33:44Z`; the complete corrected-launcher repeat and cleanup finished
at `08:44:58Z`. Reproduction uses the [current runbook](/docs/headless-agent-host.md),
not private temporary orchestration scripts or the August archive below.

| Evidence boundary                              | Result                                                                                                                                                                                   |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Outside CADE, issue-author historical test     | CLI 1.139.1, pinned AHPX, inference and cross-client continuation reported; not repeated here and not workspace proof. Its default-protocol rejection does not describe the new runtime. |
| New real Coder infrastructure                  | Headless host start, local authenticated 0.10.0 initialize/discovery, SSH-forwarded initialize, separate fresh-client reconnect and negative controls verified.                          |
| Provider sign-in / inference                   | Untested; two discovered providers advertised zero models each. No provider credentials supplied.                                                                                        |
| Sessions / UI / restart durability             | Zero active sessions observed locally; no session creation, same-session resumption, active-turn, host-restart or workspace-restart durability tested.                                   |
| Final corrected-wrapper E2E / HUMAN acceptance | Coordinator real E2E passed; human acceptance pending. Automated evidence does not supply human signoff.                                                                                 |

### Workspace recovery and security boundary

- Coder CLI/server `2.36.4+10fd510`, isolated healthy `coder`/`coder-db`, loopback
  port 7080 and private test login. The unchanged image built in 470 seconds:
  `sha256:05e291fad3f6eed1993c7c302e01838fde28a702c862dd7ee9be43566a9fdc7c`,
  amd64, 2,722,058,612 bytes, no registry digest or Microsoft binary baked in.
- One template `docker-workspace`, version `issue132-step3`
  (`0cc937fd-742d-4e11-bc93-99b84e0461a3`), workspace `local132`
  (`06ff0855-d7e4-4174-a165-dcb1b8e35c39`), nine explicit blank/default/false
  parameters, no project/provider credentials, optional apps disabled.
- Initial Docker error: `unable to apply apparmor profile` with a procfs ENOENT.
  Kernel audit: `change_onexec`, `label not found`, `error=-2` for
  `cade-bwrap-workspace`. Default-profile probes passed; custom/missing labels
  failed. The missing label, not a missing procfs attribute, caused the failure.
  Why the earlier load was absent remains unknown; no runtime downgrade justified.
- After human loading, actual retry succeeded: build 3
  `6cf565ac-9527-4306-8947-2cabbf670c79`, one connected/ready agent, startup
  complete, original home volume and image retained. Authenticated Coder SSH
  observed UID/GID 1000, x86-64, Node **20.20.2**, npm **10.8.2**, bwrap **0.9.0**,
  socat, code-server and initially no Microsoft `code` executable.
- Required AppArmor **`cade-bwrap-workspace (enforce)`**, scoped seccomp mode 2,
  `privileged=false`, no added capabilities; bwrap allow/deny controls worked.
  Separate srt secret-glob write negative control **failed**, tracked in
  [#134](https://github.com/tbrandenburg/cade/issues/134), not fixed here.
  Standalone host was not srt-wrapped; discovery does not exercise tool sandboxing.
  No full filesystem/network agent-isolation claim. Doctor's unknown result is
  tracked separately in [#133](https://github.com/tbrandenburg/cade/issues/133).

### Exact distribution, runtime and client

| Artifact                                                       | Version / identity                                  | Independently checked SHA-256                                                    |
| -------------------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------- |
| Microsoft `cli-linux-x64` (archive contains only `code`)       | 1.139.1, `04c0d99f4fb0d8afe6ce4f0c58e31e183ac3e4b1` | `e079ddb70377cca515ab0cf5ca1ee4095a14e1f510af4b10a75b01c6018f9f02`               |
| Actual installed Microsoft server, matching separate reference | 1.142.0, `6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1` | Archive `f1ee2833c6323ee03e49d46351e834c44811c53d14ba178f5debdb84a5eb7876`       |
| AHPX internal real library, package 0.7.0                      | `a88f9ba25105661fd6a63de41559362ddb2bbbe5`          | Exact Git commit, clean tracked source and built-client hash checked by verifier |

The CLI independently selects **latest stable server**; pinning CLI 1.139.1 does
not pin runtime 1.142.0. Bootstrap fails closed on latest-version/commit drift.
Actual process executable and server-main argv were independently bound to the
installed tree; full reference comparison before/after smoke: **3,791 entries,
zero mismatches**, tree digest
`fcd6bb874e8c3cef0ea5cc3ba71cb2efc61760834532a7f32e0a6af335a3e521`.
Bundled server Node **24.21.0** is distinct from workspace client Node **20.20.2**.
Official product/server and bundled pre-release Remote Development licenses were
reviewed for isolated individual evaluation; CLI startup automatically supplies
server acceptance. No redistribution, image addition or shared-service approval.

Exact client recipe: `npm ci --ignore-scripts --no-audit --no-fund` (152 packages),
`npm run build`, `npm run typecheck`, then
`./node_modules/.bin/tsup src/client/index.ts --format esm --target node20 --out-dir proof-lib --dts`.
Each passed inside the actual Node 20 workspace. Internal library is not a
published package-root export. Lockfile runtime dependencies: protocol **1.0.0**,
three dev-tunnels direct packages **1.3.48**, commander **13.1.0**, picocolors
**1.1.1**, ws **8.19.0**; build tools tsup **8.5.1**, TypeScript **5.9.3**.

### Condensed real-host transcript and independent gates

Commands below are command shapes from the run, with private paths represented
by variables; execute the guarded [runbook](/docs/headless-agent-host.md) on a
new evaluation instead. No endpoint token, raw provider resource or raw log is
included in this durable transcript.

```text
code --version; code agent host --help                 -> exit 0, non-root workspace
code --cli-data-dir "$cli_data" agent host --new-instance --foreground
  --host 127.0.0.1 --port 0 --connection-token-file "$token_file"
  --server-data-dir "$server_data" --user-data-dir "$user_data"
                                                      -> owned host, loopback 39873
bash scripts/verify-headless-agent-host.sh
  --install-root "$tools" --runtime-dir "$actual_runtime" --token-file "$token_file"
  --endpoint ws://127.0.0.1:39873 --protocol-version 0.10.0 --timeout-ms 60000
                                                      -> local initialize/discovery, exit 0
ssh -F "$private_config" -N -T -o ExitOnForwardFailure=yes
  -L 127.0.0.1:40503:127.0.0.1:39873 "$coder_ssh_host"     -> loopback-only forward
bash scripts/verify-headless-agent-host.sh
  --install-root "$operator_tools" --runtime-dir "$actual_runtime_snapshot"
  --token-file "$operator_token" --endpoint ws://127.0.0.1:40503
  --protocol-version 0.10.0 --timeout-ms 60000            -> repeated fresh-client exit 0
```

| Independent gate / control       | Observed result                                                                                                                                                                                                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Dedicated host                   | `--new-instance`, foreground supervisor PID 1534, UID 1000; private 0700 tree, 0600 token/logs, isolated HOME, tested provider/Coder credential keys absent. Host-spawned bundled Copilot runtime, no separate provider CLI installed.                                   |
| Local token + initialize         | Authenticated real `AhpClient`; protocol 0.10.0, serverSeq 5, one root snapshot, connected, zero active sessions.                                                                                                                                                        |
| Discovery                        | `copilotcli` / Copilot and `claude` / Claude, **0 models each**; two protected resources per provider omitted from reports. No sign-in/inference claim.                                                                                                                  |
| Authentication negatives         | Absent and invalid transport token each **HTTP 403**, neither initialized. Verifier invalid-token result exit 1, `connection-auth`. A missing token file alone is not this network test.                                                                                 |
| SSH forwarding / fresh reconnect | Private Coder SSH config and actual authenticated route; only 127.0.0.1:40503 listener. Separate verifier PIDs 413307 and 413993 initialized at 0.10.0; not session resumption.                                                                                          |
| Remote runtime trust             | Actual runtime copied by binary tar through authenticated SSH; independent remote process binding and fresh complete tree comparison before/after, operator snapshot compared against independently downloaded reference. Not cryptographic remote endpoint attestation. |
| Default protocol control         | Constructor override genuinely omitted; offered **[1.0.0,0.9.0]**, negotiated **1.0.0 successfully twice**, exit 0. Original expected rejection was disproven.                                                                                                           |
| Explicit unsupported offer       | **9.9.9**, initialized false, exit 1, `protocol`. Safe scan of 16 real JSONL files / 16 initialize requests correlated one error **RPC -32005** to [9.9.9], not to successful default negotiation.                                                                       |
| Post-test real smoke             | After installed tests restored source/bundle, initialize/discovery passed again, runtime 3,791/0. This predates the launcher correction.                                                                                                                                 |

Microsoft LoopbackAuth requires `tkn` in the WebSocket query; the helper reads
the private file and constructs that query only in memory. Pinned CLI provider
tokens apply **after** initialize and its URL banner could disclose the transport
token. Therefore the new verifier uses unchanged pinned `AhpClient`, not the CLI
auth helpers or a custom protocol implementation. The
[legacy verifier](/scripts/verify-ahp-session.sh) is unchanged/unvalidated here.

### Launcher correction and validation boundary

Historical step-6 wrappers reset PATH to system **Node 18.19.1** despite the
operator selecting Node 24.15.0. Those successful remote wrapper runs are **not**
a supported Node 18 deployment claim. A separate unmodified-helper remote smoke
used Node 24.15.0 successfully; workspace client remained Node 20.20.2.

The corrected public launchers preserve the selected absolute Node >=20,
including npm shebang execution, then clear inherited credentials/debug options.
The old `CADE_CLEAN_ENV` bypass was removed. Unsupported Node fails before writes
or JS import. Coordinator independently accepted the **18-test** correction gate:
14 unit/launcher + 4 installed integration tests, **18 pass / 0 fail / 0 skip**,
syntax, ShellCheck and formatter checks passed. Installed real-client transport
subprocess interpreter equality was checked via procfs (Node 24.15.0).
Synthetic credential/old-marker and malicious NODE_OPTIONS controls did not
escape sanitization. No global Node/config change.

Earlier step-5/6 focused baseline was **11 + 4 = 15** tests; unrelated prior
19-test system totals are not this suite. Installed rejection/stall, drift and
source/bundle tamper fixtures are integration checks, not real Microsoft E2E.
**Final coordinator repeat:** fresh workspace and operator installations both
used the corrected public bootstrap. The actual local verifier ran Node 20 and
the operator verifier ran Node 24, checked by process executable identity.
Actual runtime binding and full-tree comparison passed before/after; repeated
fresh client processes negotiated 0.10.0 with the same discovery counts above.
Missing/invalid tokens received 403; default negotiation succeeded at 1.0.0;
explicit 9.9.9 was rejected. The final summary recorded `validationPassed:true`,
`failure:null`, and `cleanupFailures:[]`.

Two earlier coordinator harness attempts failed and are not passing evidence:
the first waited for the request-lazy backend before sending any request; the
second froze a transient empty SSH cmdline during exec, then rejected its later
identity. Both were diagnosed with controls; the second's retained tunnel was
recovered by exact identity checks. The passing repeat separated proxy readiness
from backend startup and settled launch identities before freezing them.
The runbook now sends the first authenticated AHP request before inspecting
backend binding. These were temporary validation-harness fixes, not host-runtime
downgrades or security relaxations.

Final supervisor PID 16805 and private tunnel port 49001 were test-owned.
Cleanup captured five host and two tunnel processes: **zero live captured
processes, zero zombies, both listeners closed**. Isolated workspace evaluation
root, private tokens and raw logs were removed; `local132` and Coder remain
available for human acceptance. Sanitized coordinator records are retained at
`/tmp/opencode/issue132-final/attempts/retry2/evidence/`; this durable summary does
not require those temporary files to reproduce the runbook.

### Cleanup, retained resources and remaining acceptance

- Before teardown, captured host tree identities (UID/start ticks/cmdline hash)
  were refreshed: **1534,6301,6305,6326,6338**. Exact-PID cleanup found **zero live
  captured processes, zero zombies, former host port 39873 closed**.
- Tunnel identities **410179,410180** independently checked/stopped by exact PID;
  **zero live captured processes, port 40503 closed**. No name-based kill.
- Sanitized evidence preserved before removing owned workspace evaluation
  directories, token/registry/raw host logs and installs. Operator token/private
  configs, raw install/tunnel logs and redundant transfer artifacts removed.
  Token scan: **356 repository/evidence files, zero matches** outside private
  paths before unlink. No raw AHP JSONL copied into the report.
- Dedicated operator client installation/runtime snapshot and sanitized evidence
  retained for independent tests. Coder/DB, `local132`, its container/home volume
  remain available; final independent SSH still reached UID 1000. No workspace
  delete/restart, historical-volume deletion, profile change or shared-process kill.
  Historical volumes remained detached/intact and operator config unchanged.
- Non-blocking native warning: missing runtime-bundled skills; recorded, not
  fixed. No bwrap startup error observed during discovery; no inference/tool
  sandbox conclusion. Informational zero-failure log summaries were not failures.

Acceptance checklist:

- [x] Automated real-workspace distribution, startup, local auth/initialize and discovery.
- [x] Automated private SSH forward, fresh-client discovery and exact negative outcomes.
- [x] Original host/tunnel cleanup independently verified; no credentials provisioned.
- [x] Corrected launchers independently accepted with 18 focused tests.
- [x] Coordinator repeats full bootstrap/remote E2E through corrected public launchers.
- [ ] HUMAN reproduces/signs #132's final checklist on a fresh real workspace.
- [ ] Separate M4 session/UI/restart durability evidence (not required to close infrastructure #132).

Follow the [runbook](/docs/headless-agent-host.md#4-cleanup-and-acceptance) for
human acceptance. Existing follow-ups #133/#134 remain separate; no new follow-up
is required by this documentation-only reconciliation.

## Historical evidence (August; superseded conclusions noted above)

**Archived, non-executable record:** commands and checklist entries below refer
to the deleted `m4-e2e` workspace and the versions tested then, not a current
resume procedure. Use the [current runbook](/docs/headless-agent-host.md)
with a fresh authorized workspace. The legacy verifier is unvalidated for
standalone AHP 0.10.0; a Desktop connection alone does not resolve that gap.

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

**Historical interpretation, not a current prerequisite:** the Agent Host process
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

**Not completed — archived, non-executable Desktop persistence checklist.**
The headless infrastructure test in issue #132 is a separate acceptance gate;
Desktop is not required to launch the documented standalone host. The original
"no headless CLI" rationale is obsolete. Steps 1–2 below record historical
setup only, not reusable prerequisites: `m4-e2e` was deleted. Do not resume at
step 3; follow the current runbook's fresh-workspace gates instead.

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

The former instruction to rerun the legacy verifier on `coder.m4-e2e` is
withdrawn: that workspace no longer exists, and authenticated standalone
0.10.0 initialize/discovery must be verified through the current runbook.

## Cleanup

The test workspace was deleted after capturing all evidence above:

```
$ coder delete m4-e2e --yes
...
m4-e2e has been deleted.
```

## Historical answer to the required question

_Is the Durable Session Plane (VS Code Agent Host / AHP) reachable and
correctly configured, independent of the workspace container and any
specific LLM harness?_

**Not demonstrated — authenticated AHP and live session persistence were not
verified.** The historical setup evidence covers workspace/SSH configuration,
not a reachable session plane. The original account below describes what was
checked at that time, not a current headless-bootstrap limitation:

The historical transcript records a public-repo clone without credentials,
first-boot sandbox/session-locality settings, SSH reachability, and verifier
failures with no host present. It does not establish current configuration or
authenticated protocol compatibility. Session survival across editor reconnects
was not demonstrated. Desktop interaction belongs to that separate UI scenario,
not a prerequisite for standalone host startup or headless AHP verification.
For the new automated infrastructure result and its untested durability boundary,
see [Current status](#current-status--automated-infrastructure-verified-human-acceptance-pending).
Final human fresh-workspace E2E signoff remains required; issue #132 stays open.
