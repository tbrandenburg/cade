# M9 Agent/Harness Integration — Milestone Report

Evidence captured for Phase 1 / Milestone M9 (Agent/Harness Integration), per
the evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`docs/plan/plan.md` (M9 section).

- **Timestamp (UTC):** 2026-08-28T13:40Z
- **Environment:** local Coder server (`ghcr.io/coder/coder:v2.36.3`),
  `docker-workspace` template (active version `busy_gilbert81`), workspace
  image `devenv-cloud/coder-workspace:latest` rebuilt locally with this
  milestone's `coder/Dockerfile` changes, authenticated as `m3reviewer`.
  Backend model providers used for the Agent Test: `opencode/big-pickle`
  (zero-config, no credentials) and OpenAI `gpt-4o-mini` (via the
  pre-existing `OPENAI_API_KEY` in this environment) for `pi`, since `pi`
  has no zero-config equivalent.

## What was built

- `coder/Dockerfile` — adds `bubblewrap`, `socat`, `ripgrep`, `tmux`, the
  `opencode` CLI (installed via `opencode.ai/install`), the `pi` CLI
  (`@earendil-works/pi-coding-agent` via npm), and Anthropic's Sandbox
  Runtime (`srt`, `@anthropic-ai/sandbox-runtime` via npm) — both harnesses,
  not optional, per this milestone's objective.
- `agent-host/srt-settings.json` — versioned `srt` sandbox template:
  network allowlist (GitHub + Copilot proxy endpoints), `denyRead` covering
  `~/.ssh`, `~/.aws`, `.env`, and both agent CLIs' own credential stores
  (`~/.claude`, `~/.copilot`) so neither harness can read the other's
  credentials, `denyWrite` for secrets, and `enableWeakerNestedSandbox: true`
  (see "Known limitation: `srt`/`bwrap` cannot enforce inside this Docker
  environment" below for why).
- `coder/templates/docker-workspace/main.tf` — startup script now copies
  `agent-host/srt-settings.json` to `~/.srt-settings.json` on first boot only
  (persistent home volume, same pattern as M4's `.vscode/settings.json`),
  and appends `alias opencode='srt opencode --'` / `alias pi='srt pi --'` to
  `~/.bashrc` once.
- `scripts/verify-agent-tmux-session.sh` — starts/reattaches a named tmux
  session, records the wrapped process's PID, disconnects, reconnects, and
  confirms the same PID survived — the process-continuity proof called for
  in place of AHP durability (which `opencode`/`pi` do not get, since
  neither is an AHP adapter).

## Validation Milestone M9

Both `opencode` and `pi` were run against the same seeded failure, first in
a scratch local clone, then live on a real Coder workspace (`m9-e2e`,
created from the `docker-workspace` template, image rebuilt with this
milestone's Dockerfile). Both saw repository context directly (reading
`hello.py`/`test_hello.py`, running `make test` themselves) with no manual
copying of the repository into chat, and both correctly identified the root
cause.

**Default harness for later milestones (M10's `gh-aw`, M11's agent-driven
MCP calls): `opencode`.** Reasoning: it has a genuine zero-config path
(`opencode/big-pickle`, confirmed working with no `ANTHROPIC_*`/`OPENAI_*`/
`COPILOT_*`/`OPENCODE_*` env vars set) suited to CI-style automation, whereas
`pi` always needs a configured provider. `pi` remains installed and
available as the second supported harness per this milestone's objective,
not removed.

### Agent Test — `opencode` (`opencode/big-pickle`, zero-config)

Seeded failure: `examples/hello-service/hello.py`'s `greeting()` changed
from `f"Hello, {name}!"` to `f"Hello {name}!"` (missing comma), on a
scratch branch, in a scratch local clone (never pushed/committed to this
repository).

```
$ opencode run --model opencode/big-pickle "Investigate why the tests in \
    examples/hello-service fail. Run the test suite yourself. Do not \
    modify code. Return: root cause, affected file, recommended fix."
...
$ make test 2>&1; echo "EXIT_CODE=$?"
test_default_greeting ... FAIL
test_named_greeting ... FAIL
test_empty_name_raises ... ok
FAILED (failures=2)
EXIT_CODE=2

Confirmed: 2 of 3 tests fail (`FAILED (failures=2)`, exit code 2).

Root cause: Implementation produces "Hello {name}!" (no comma after
"Hello"), but the tests assert "Hello, {name}!" (with comma). hello.py:12
returns f"Hello {name}!"; test_hello.py:8 and test_hello.py:11 expect
"Hello, world!" / "Hello, Coder!".

Affected file: examples/hello-service/hello.py:12 (the tests in
test_hello.py:8,11 encode the correct contract).

Recommended fix: hello.py line 8 -> return f"Hello, {name}!" (align
implementation with the test contract; "Hello, world!" is the canonical
form). Verify with `make test` -- all 3 should pass.
```

Correct root cause, correct affected file/line, correct fix. No code was
modified (confirmed: `git status` showed only the pre-seeded change).

### Agent Test — `pi` (OpenAI `gpt-4o-mini`)

Same seeded failure, same scratch clone:

```
$ pi --provider openai --model gpt-4o-mini -p "Investigate why the tests \
    in examples/hello-service fail. Run the test suite yourself. Do not \
    modify code. Return: root cause, affected file, recommended fix."
...
Root Cause: The tests ... expect a comma in the greeting string, while the
actual function returns the string without it.
  - greeting() returns "Hello world!" (actual) vs "Hello, world!" (expected)
  - greeting("Coder") returns "Hello Coder!" (actual) vs "Hello, Coder!" (expected)
Affected File: examples/hello-service/test_hello.py
Recommended Fix: Modify the implementation of the greeting function to
include commas ...
```

Correct root cause and fix; `pi` named `test_hello.py` as "the affected
file" (the test encodes the intended contract; the actual bug is in
`hello.py`) rather than `hello.py` — a minor imprecision, not a diagnostic
failure. No code was modified.

### Re-run against a real Coder workspace (`m9-e2e`)

```
$ coder create m3reviewer/m9-e2e --template docker-workspace \
    --parameter github_token=*** --parameter agent_capable=false --yes
...
The m9-e2e workspace has been created at Aug 28 15:38:20!

$ ssh coder.m9-e2e "which tmux opencode pi srt bwrap"
/usr/bin/tmux
/usr/local/bin/opencode
/usr/bin/pi
/usr/bin/srt
/usr/bin/bwrap
```

Seeded the same one-line bug on a scratch branch (`agent-test-m9-remote`,
never merged/pushed) directly on the workspace's `~/project` checkout, ran
`opencode run --model opencode/big-pickle` over SSH — same correct
diagnosis as the local run above (`make test` shows `FAILED (failures=2)`,
root cause/affected file/fix all correct). The scratch branch and its
change were discarded afterward (`git checkout main && git branch -D
agent-test-m9-remote && git checkout -- hello.py`); `git status --short`
confirmed a clean tree (only the pre-existing untracked `.vscode/` from
M4) before the workspace was deleted.

## Manual E2E Test M9

1. **Fresh agent workspace:** `m3reviewer/m9-e2e`, created from the
   `docker-workspace` template with the rebuilt image (above).
2. **Authenticate the selected provider:** N/A for the Agent Test itself —
   `opencode/big-pickle` needs no credentials; `pi` used this
   environment's pre-existing `OPENAI_API_KEY`.
3. **Intentionally break the sample project:** done twice (local scratch
   clone, and the live workspace), see above.
4. **Ask the agent to diagnose (`opencode` first, then `pi`):** done, see
   above — both wrapped-harness-capable, though see the sandbox limitation
   below regarding whether `srt` itself could be verified as actually
   enforcing during these specific runs.
5. **Compare diagnosis with the known problem:** matches — missing comma
   in `hello.py`'s `greeting()`, both harnesses.
6. **Transcript/evidence saved:** captured above (this report) for both
   CLIs, both locally and on the live workspace.
7. **Confirm the sandbox actually restricts the agent** — **FAILED, known
   limitation, see below.**
8. **Confirm cross-credential isolation** — **not verifiable, same
   limitation** (blocked before either credential-read attempt could be
   evaluated).

### Known limitation: `srt`/`bwrap` cannot enforce inside this Docker environment

`srt` unconditionally wraps every command in an outer `bwrap
--unshare-user` sandbox (confirmed by reading
`@anthropic-ai/sandbox-runtime`'s `linux-sandbox-utils.js`:
`enableWeakerNestedSandbox` only changes whether `--cap-drop ALL` is added
to that same `--unshare-user` invocation — it does not remove the
requirement for creating a user namespace at all). In this Docker/WSL2
environment, `bwrap --unshare-user` itself fails unconditionally:

```
$ docker run --rm devenv-cloud/coder-workspace:latest bash -lc \
    'bwrap --unshare-user --unshare-pid --ro-bind / / echo ok'
bwrap: No permissions to create new namespace, likely because the kernel
does not allow non-privileged user namespaces. See
<https://deb.li/bubblewrap> or <file:///usr/share/doc/bubblewrap/README.Debian.gz>.
```

Diagnosis performed per the step's own instructions:

- `cat /proc/sys/kernel/unprivileged_userns_clone` and
  `/proc/sys/kernel/apparmor_restrict_unprivileged_userns` — **neither file
  exists** on this host (WSL2 kernel `6.18.33.2-microsoft-standard-WSL2`),
  so neither documented host-level knob applies here.
- Setting `enableWeakerNestedSandbox: true` in `agent-host/srt-settings.json`
  (done, and left in place) made **no difference** — reproduced against the
  live workspace with the setting in place:

  ```
  $ ssh coder.m9-e2e "srt -c 'cat ~/.ssh/id_rsa'"
  bwrap: No permissions to create new namespace, ...
  exit=1
  ```

  (Failed as intended for the wrong reason: `srt` never got to enforce its
  `denyRead` rule, because `bwrap` itself couldn't start at all.)
- Isolated the true cause: adding `--cap-add SYS_ADMIN` alone got further
  (`bwrap: pivot_root: Operation not permitted` — a different, AppArmor
  `docker-default`-profile failure), and only
  `--security-opt seccomp=unconfined --security-opt apparmor=unconfined`
  made the same `bwrap --unshare-user ... echo ok` smoke test succeed. That
  is, Docker's *default* seccomp/AppArmor confinement on the workspace
  container itself is what blocks unprivileged user namespace creation
  here, independent of any host `sysctl`.
- Per the step's explicit instruction, this is **not** treated as a green
  light to add `--privileged` or `--security-opt seccomp=unconfined` to the
  `docker_container.workspace` resource in `main.tf` as a fix: doing so
  would weaken the Rule 1 container boundary for every workspace, not just
  restore `srt`'s own (already-optional, defense-in-depth) sandboxing —
  a security posture change of that scope is out of this step's authority
  to make unilaterally. `main.tf`'s `docker_container.workspace` is left at
  Docker's default seccomp/AppArmor profile.

**Consequence:** in this specific deployment, `srt` is installed, aliased,
and configured correctly, but does not currently provide the filesystem/
network sandboxing or cross-credential isolation it is designed for —
`opencode`/`pi` here run exactly as they would unwrapped. This mirrors the
step's own framing of `srt` as "beta research preview... an additional
layer, not a replacement for the workspace/runner isolation already
required by Rule 1/Rule 6" — the workspace container's own isolation (Rule
1) remains the operative boundary until either the host is reconfigured to
permit unprivileged user namespaces for this container (a decision for
whoever owns the Coder host, being a security-posture change) or `srt`
ships a mode that does not require any user namespace at all.

## Lessons learned

See `AGENTS.md` "Lessons Learned" for the M9-specific pitfall (`srt`/`bwrap`
unconditionally requires a working `bwrap --unshare-user`, which
`enableWeakerNestedSandbox` does not remove the need for).
