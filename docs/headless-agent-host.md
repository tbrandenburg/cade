# Headless Microsoft Agent Host

Provision a private, manually launched Microsoft host in one disposable Coder
workspace; verify authenticated AHP discovery locally, then through SSH.
Owner: the evaluating operator. Recheck pins and licenses before each evaluation.

**Status:** automated real-host infrastructure proof and the final coordinator
repeat through corrected public launchers succeeded, verified at
`2026-10-15T08:44:58Z`. **HUMAN fresh-workspace acceptance remains pending**.
Issue [#132](https://github.com/tbrandenburg/cade/issues/132) stays open.
See the [M4 evidence report](/docs/milestone-reports/M4-agent-host.md) for versions,
protocol controls, cleanup and the historical evidence boundary. Discovery is
not provider sign-in, inference, session resumption or M4 durability acceptance.

## Prerequisites and safety boundary

- Linux x86-64, non-root user, Bash, Python 3, Node **>=20** selected by your
  normal PATH, npm, Git, curl, tar, sha256sum, timeout and OpenSSH. Tested workspace
  client: Node 20.20.2; selected operator client: Node 24.15.0. Neither is the
  Microsoft server's bundled Node 24.21.0. Do not upgrade global Node.
- An authorized, fresh/disposable `docker-workspace` with connected/ready Coder
  agent, working SSH, and matching Coder CLI/server (tested 2.36.4+10fd510).
  Supply every template parameter explicitly; use blank repo/provider credentials
  and disabled optional apps. Build/push only the intended template if necessary;
  retain the existing dirty-tree build guard. See [quickstart](/README.md#quickstart).
- The host operator must have loaded the intended
  [security profiles](/scripts/load-security-profiles.sh). The earlier unloaded
  AppArmor-label failure was resolved by human loading; `local132` subsequently
  ran under `cade-bwrap-workspace (enforce)`. Never bypass AppArmor/seccomp.
  bwrap allow/deny checks passed, but the separate srt secret-glob write control
  failed ([#134](https://github.com/tbrandenburg/cade/issues/134)); this runbook
  makes no complete agent-sandbox claim. Doctor's unknown result is separate
  [#133](https://github.com/tbrandenburg/cade/issues/133), not a passed prerequisite.
- Use dedicated shells with no provider credentials and a checkout containing
  these scripts in both workspace and operator environments. Do not mount host
  credentials, install provider CLIs, or invoke AHPX provider-auth helpers.
  code-server is **not** Microsoft's standalone host.

Review the [product license](https://code.visualstudio.com/License),
[server license](https://code.visualstudio.com/license/server), and downloaded
`runtime-reference/LICENSE` **before starting**. The bundled pre-release Remote
Development license has different wording from the website server license.
The tested CLI automatically passes `--accept-server-license-terms` to its server
child: manual startup is a consent boundary, not an opportunity to await a prompt.
Do not invent a host acceptance flag. This individual evaluation is not approval
to redistribute binaries, bake them into an image, or offer a shared service.
Official guides: [standalone host](https://code.visualstudio.com/docs/agents/concepts/agent-host#_run-a-standalone-host),
[CLI distribution](https://code.visualstudio.com/docs/remote/tunnels#_using-the-code-cli).

## 1. Bootstrap inside the workspace

Run Bash snippets from the repository root in a dedicated fail-fast shell. The
new target must sit under an existing, real, user-owned **0700** parent:

```bash
set -euo pipefail
umask 077
run=$(mktemp -d "$HOME/cade-headless.XXXXXX")
bash scripts/bootstrap-headless-agent-host.sh --install-root "$run/tools"
mkdir "$run/private"
python3 - "$run/private/connection-token" <<'PY'
import os, secrets, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as stream:
    stream.write(secrets.token_hex(32))
PY
```

Bootstrap verifies the official CLI archive/version, latest-server metadata and
independently downloaded reference archive. It fetches exact AHPX
`a88f9ba25105661fd6a63de41559362ddb2bbbe5` (0.7.0), runs
`npm ci --ignore-scripts --no-audit --no-fund`, build/typecheck, then builds its
unchanged internal `src/client/index.ts` with installed tsup (`--format esm
--target node20 --out-dir proof-lib --dts`). This is not a package-root export.
It records `manifest.json` and client hash; **does not start a host or accept
server terms**. Keep `install.log` private; a failed/partial target is not reused.

Both public launchers resolve the current external Node executable before
unconditionally clearing the environment; the first engine probe also runs
clean. Bootstrap retains its directory for npm shebangs; verifier executes the
absolute selected Node. Provider credentials/Node debug options are not inherited.
No `CADE_CLEAN_ENV` marker is needed or honored as a bypass. Invoke only the
public bootstrap above, not its private `scripts/lib/` implementation.

CLI **1.139.1 does not pin the server**: it selects latest stable independently.
The scripts deliberately fail closed unless latest is reference **1.142.0**,
commit `6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1`. On drift, stop and review
official artifacts, license and compatibility; do not bypass hashes, invent
version/cache flags or silently change pins. Full hashes are in the M4 report.

## 2. Start manually, verify locally first

**Workspace terminal A:** after license review, keep this new host in the
foreground. Raw stdout can contain endpoint tokens: redirect to the private log;
do not tail, screenshot or publish it. Port 0 requests a free ephemeral port.

```bash
set -euo pipefail
: "${run:?Use the workspace evaluation directory from step 1}"
printf '%s\n' "$$" > "$run/private/host.pid"
exec env -i HOME="$run/tools/home" PATH=/usr/local/bin:/usr/bin:/bin \
  "$run/tools/cli/code" --cli-data-dir "$run/cli-data" agent host \
  --new-instance --foreground --host 127.0.0.1 --port 0 \
  --connection-token-file "$run/private/connection-token" \
  --server-data-dir "$run/server-data" --user-data-dir "$run/user-data" \
  > "$run/private/host.log" 2>&1
```

**Workspace terminal B:** set `run` to terminal A's non-secret directory.
Use `ss -ltnp` to find the dedicated host's port; verify its only owned TCP
listener is `127.0.0.1`, never `0.0.0.0`. Set `host_port` to that observed port.
Do not print the private endpoint registry to discover it. The CLI downloads its
runtime eagerly, but starts the backend on the first authenticated request.
Run the local verifier first, then inspect actual process binding without
printing argv (it may contain secrets):

```bash
set -euo pipefail
umask 077
: "${run:?Set the workspace evaluation directory}"
: "${host_port:?Set the observed loopback host port}"
runtime="$run/cli-data/servers/Stable-6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1/server"
bash scripts/verify-headless-agent-host.sh \
  --install-root "$run/tools" --runtime-dir "$runtime" \
  --token-file "$run/private/connection-token" \
  --endpoint "ws://127.0.0.1:$host_port" \
  --protocol-version 0.10.0 --timeout-ms 60000
python3 - "$run" "$runtime" <<'PY'
import json, os, sys
from pathlib import Path
root, runtime = Path(sys.argv[1]), Path(sys.argv[2])
owned = {int((root/'private/host.pid').read_text())}
processes = {}
for path in Path('/proc').iterdir():
    if not path.name.isdigit():
        continue
    try:
        fields = (path/'stat').read_text().rsplit(')', 1)[1].split()
        if path.stat().st_uid == os.getuid():
            processes[int(path.name)] = (int(fields[1]), path)
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue
while True:
    children = {pid for pid, (parent, _) in processes.items() if parent in owned}
    if children <= owned:
        break
    owned |= children
bound = []
for pid in owned:
    path = processes[pid][1]
    args = (path/'cmdline').read_bytes().split(b'\0')
    if os.fsencode(runtime/'out/server-main.js') in args:
        assert (path/'exe').resolve() == runtime/'node'
        assert b'--agent-host-path' in args
        bound.append(pid)
assert len(bound) == 1
print(json.dumps({'runtimeProcessBound': True, 'uid': os.getuid(), 'pid': bound[0]}))
PY
```

Require `initialized:true`, negotiated `0.10.0`, root snapshot and actual provider
counts. Tested result: serverSeq 5, one snapshot, `copilotcli` and `claude`, zero
models each and zero sessions; provider availability/sign-in is unknown.
Verifier hashes the **actual** server tree against the independently downloaded
reference before/after discovery (3,791 entries, zero mismatches in the proof).
Never pass `runtime-reference` as though it were the running host directory.

Transport uses Microsoft's `tkn` query, assembled only in process memory from
the private 0600 token file. Do not put tokens in argv, environment, URLs or
transcripts. Pinned AHPX CLI prints its target URL and can enter provider auth;
the verifier uses the real library instead and emits only allowlisted JSON.

## 3. Forward over private Coder SSH

**Operator terminal A:** choose an unused private parent (different HOME/tree
from the workspace). Login interactively to the authorized deployment with a
new private config, not a historical operator session. Do not record credentials.
The installed Coder help supports `config-ssh --ssh-config-file`; no global
`~/.ssh/config` write is needed.

```bash
set -euo pipefail
umask 077
operator=$(mktemp -d "$HOME/cade-headless-client.XXXXXX")
mkdir "$operator/private"
: "${coder_url:?Set the authorized Coder URL without credentials}"
: "${workspace:?Set the disposable workspace name}"
coder=$(command -v coder)
"$coder" --global-config "$operator/private/coder-config" --url "$coder_url" login "$coder_url"
"$coder" --global-config "$operator/private/coder-config" --url "$coder_url" \
  config-ssh --ssh-config-file "$operator/private/ssh-config" --yes
```

Inspect the generated **private** ProxyCommand. It must use that actual Coder
binary with `--global-config "$operator/private/coder-config" --url "$coder_url"`
before `ssh --stdio --wait yes --disable-autostart WORKSPACE`; edit only the
private file if the generated command omits those global options. Use its actual
host alias as `ssh_host`. Verify authenticated SSH reaches the non-root workspace.
Keep config/session files private (0700 directories, 0600 files).

**Operator terminal B:** set `operator`, `ssh_host`, `remote_run`,
`remote_runtime` and `host_port` to the independently inspected workspace values;
paths/alias must contain only letters, digits, `/`, `.`, `_` or `-` for the quoted
remote commands below. **Before transfer**, repeat workspace terminal B's
process-binding inspection and local verifier through authenticated SSH; require
the same actual runtime binding and fresh whole-tree comparison. Run the public
bootstrap normally, then transfer the token straight to a private file and the
**actual runtime** as binary tar:

```bash
set -euo pipefail
umask 077
: "${operator:?Set the operator directory}" "${ssh_host:?Set the private SSH alias}"
: "${remote_run:?Set the workspace run directory}" "${remote_runtime:?Set the actual runtime}"
for value in "$ssh_host" "$remote_run" "$remote_runtime"; do
  [[ $value =~ ^[A-Za-z0-9/._-]+$ ]] || exit 1
done
bash scripts/bootstrap-headless-agent-host.sh --install-root "$operator/tools"
ssh -F "$operator/private/ssh-config" "$ssh_host" \
  "python3 -c 'import pathlib,sys; sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes())' '$remote_run/private/connection-token'" \
  > "$operator/private/connection-token"
chmod 600 "$operator/private/connection-token"
mkdir "$operator/runtime-snapshot"
ssh -F "$operator/private/ssh-config" "$ssh_host" \
  "tar -C '$remote_runtime' -czf - ." > "$operator/private/runtime.tar.gz"
tar -xzf "$operator/private/runtime.tar.gz" -C "$operator/runtime-snapshot"
```

**After remote smoke**, repeat that independent remote binding/local-verifier
check and record sanitized counts. The operator helper verifies the transferred
snapshot against its own reference, **not an arbitrary remote process**. This is
trusted SSH inspection plus a verified snapshot, not cryptographic endpoint
attestation. Never substitute a local reference tree for this transfer.

Choose `forward_port` only after checking it is free (example check below), then
start the tunnel in **operator terminal A**, foreground with a captured exact PID.
Carry the variables into that shell; do not bind publicly or enable agent forwarding.

```bash
set -euo pipefail
: "${operator:?Set the operator directory}" "${ssh_host:?Set the private SSH alias}"
: "${forward_port:?Choose a free operator loopback port}" "${host_port:?Set the workspace port}"
python3 - "$forward_port" <<'PY'
import socket, sys
with socket.socket() as listener:
    listener.bind(('127.0.0.1', int(sys.argv[1])))
PY
printf '%s\n' "$$" > "$operator/private/tunnel.pid"
exec ssh -F "$operator/private/ssh-config" -N -T -o ForwardAgent=no \
  -o ExitOnForwardFailure=yes -L "127.0.0.1:$forward_port:127.0.0.1:$host_port" "$ssh_host" \
  > "$operator/private/tunnel.log" 2>&1
```

In operator terminal B, confirm only the intended loopback listener, then run
twice as separate client processes:

```bash
set -euo pipefail
: "${operator:?Set the operator directory}" "${forward_port:?Set the forwarded port}"
bash scripts/verify-headless-agent-host.sh \
  --install-root "$operator/tools" --runtime-dir "$operator/runtime-snapshot" \
  --token-file "$operator/private/connection-token" \
  --endpoint "ws://127.0.0.1:$forward_port" \
  --protocol-version 0.10.0 --timeout-ms 60000
```

This is fresh-client handshake/discovery, not same-session resumption. Repeat
with `--protocol-version default`: tested offer `[1.0.0,0.9.0]` **succeeded at
1.0.0**. Explicit `9.9.9` rejected (`protocol`); actual-host safe RPC scanning
separately correlated **-32005** only with that unsupported offer. Never infer
the numeric RPC code from the helper's category alone. Test an independently
generated invalid 0600 token file: require nonzero exit and `connection-auth`.
A missing token file is input validation, not a network absent-token control;
the prior real-library absent/invalid transport controls each observed HTTP 403.

## 4. Cleanup and acceptance

1. Ctrl-C **your** foreground tunnel and host in their terminals; wait for each
   to exit. Check captured PID identity/descendants before any fallback signaling;
   signal only those exact owned PIDs, never a process-name pattern.
2. Confirm both former loopback ports refuse connections and captured processes
   are gone. Do not delete live host data/token first.
3. Preserve only sanitized versions, initialize/discovery counts, control outcomes
   and cleanup results. Scan evidence for the token **in process**, emitting only
   counts; never print secret contents or raw logs/registry/AHP JSONL.
4. Remove only this evaluation's owned token, raw logs, snapshots and install
   directories after checking no process depends on them. Keep the Coder stack,
   workspace and volume available for the pending human test; do not delete
   profiles, databases, historical volumes, local login or unrelated resources.
5. **HUMAN:** reproduce on a fresh real workspace and attach the sanitized
   transcript/checklist from #132. Do not close #132 or mark M4 durability accepted
   from automation. Provider authentication/inference and restart durability are
   separate future work, not extra prerequisites for this infrastructure issue.

## Checks and troubleshooting

```bash
set -euo pipefail
: "${operator:?Set the dedicated operator test installation directory}"
bash -n scripts/bootstrap-headless-agent-host.sh scripts/verify-headless-agent-host.sh scripts/lib/bootstrap-headless-agent-host.sh
shellcheck scripts/bootstrap-headless-agent-host.sh scripts/verify-headless-agent-host.sh scripts/lib/bootstrap-headless-agent-host.sh
node --check scripts/lib/headless-agent-host.mjs
node --test scripts/tests/headless-agent-host.test.mjs
CADE_HEADLESS_TEST_ROOT="$operator/tools" \
CADE_HEADLESS_TEST_RUNTIME="$operator/runtime-snapshot" \
  node --test scripts/tests/headless-agent-host-installed.test.mjs
git diff --check
```

Current focused suite: 14 unit/launcher + 4 installed integration tests, not a
full-system count. Installed tests temporarily tamper/restore their dedicated
installation; do not run a simultaneous smoke. TCP rejection/stall fixtures
exercise the real client but are not Microsoft E2E proof. Run an explicit
Prettier check on changed Markdown too.

| Failure                                | Action                                                                                       |
| -------------------------------------- | -------------------------------------------------------------------------------------------- |
| `unsupported-node` / Node prerequisite | Select a trusted Node >=20 on normal PATH; no global replacement or clean-marker workaround. |
| Bootstrap failure                      | Keep private log; stop on checksum/latest drift; retry only a new target after diagnosis.    |
| AppArmor `label not found`             | Human operator verifies intended loaded profile; never weaken enforcement.                   |
| `unsafe-permissions`                   | Check owned real 0700 parent and 0600 token, no symlinks.                                    |
| `runtime-drift` / `runtime-integrity`  | Recheck actual process binding, official artifact and snapshot freshness; do not bypass.     |
| `connection-auth`                      | Check private token/host pairing and loopback forward; never print URL/token.                |
| `protocol` / timeout                   | Record offered/negotiated result; total timeout includes runtime hashing, max 120000 ms.     |

The [legacy verifier](/scripts/verify-ahp-session.sh) remains unchanged and is not
validated for this standalone transport; do not use its historical result as
evidence for this path.
