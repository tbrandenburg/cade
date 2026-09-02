terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

locals {
  username      = data.coder_workspace_owner.me.name
  repo_url      = var.repo_url
  workspace_dir = "/home/coder/project"
  # Issue #43 Step 5: legible per-workspace omnigent host name, e.g.
  # "alice-my-workspace" — matches the naming scheme already discussed for
  # the omnigent server's host list.
  omnigent_host_name = "${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"

  # Issue #43 Step 5 (corrected twice — see the startup_script block below
  # for the final, live-verified mechanism): `omnigent host` has no `--name`
  # flag, and the OMNIGENT_HOST_NAME/OMNIGENT_HOST_ID env var pair does NOT
  # work either for a `--background` remote daemon (silently filtered out by
  # the daemon subprocess's own environment allowlist — verified live
  # against the real omnigent==0.11.0 source). The values below are instead
  # written directly into ~/.omnigent/config.yaml's `host:` section before
  # `omnigent host` is invoked. OMNIGENT_HOST_ID must be a bare 32-char hex
  # string. `md5()` already returns exactly that (a 32-char hex digest) — no
  # `substr()` truncation needed. Derived from the workspace's own stable
  # Coder ID (not `uuid()`, which Coder templates disallow outside specific
  # mechanisms and would change on every plan) so the SAME host_id persists
  # across `coder stop`/`start` — though since ~/.omnigent/config.yaml
  # itself already lives on the persistent home volume, this determinism is
  # now a belt-and-suspenders property rather than the only thing making
  # the identity stable.
  omnigent_host_id = md5(data.coder_workspace.me.id)
}

provider "docker" {
  host = var.docker_socket != "" ? var.docker_socket : null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# Issue #17: real GitHub external auth wiring, using the "github" external
# auth provider that S1 already configured server-side in the repo-root
# compose.yaml (CODER_EXTERNAL_AUTH_0_ID = "github"). `optional = true` so
# a workspace can still be created/started by a user who has not linked
# their GitHub identity yet — in that case `access_token` resolves to an
# empty string and the coalesce() below falls back to the pre-existing
# manual-paste `github_token` coder_parameter, kept unchanged for that
# reason (not a duplicate — genuine fallback for unlinked users).
data "coder_external_auth" "github" {
  id       = "github"
  optional = true
}

# Optional token for cloning `repo_url` when it is not publicly readable.
# Left empty, `git clone` behaves exactly as before (anonymous HTTPS clone).
# When set, the startup script clones non-interactively via GIT_ASKPASS
# instead of the repo_url itself, so the token never ends up embedded in
# .git/config or in `git remote -v` output.
data "coder_parameter" "github_token" {
  name         = "github_token"
  display_name = "GitHub Token"
  description  = "Optional token to clone `repo_url` when it is not publicly readable. Leave empty for public repos."
  type         = "string"
  default      = ""
  mutable      = true
  order        = 1
}

# This template exists specifically for long-running Coder Agent sessions,
# so `agent_capable` defaults to true here (unlike `docker-workspace`, where
# it defaults to false for human-only workspaces).
data "coder_parameter" "agent_capable" {
  name         = "agent_capable"
  display_name = "Agent-capable (disable aggressive autostop)"
  description  = "Set true for workspaces expected to run long Agent Host sessions unattended. Human-only workspaces should leave this false and keep the default autostop."
  type         = "bool"
  default      = "true"
  mutable      = true
  order        = 2
}

# Issue #13 Task 8b: optional bearer token for the `lab-sim` MCP server
# wired into the workspace's `.mcp.json`. Left empty, `.mcp.json` still
# gets written but any real call to `lab-sim` will 401 until a token is
# supplied — same optional/default-empty pattern as `github_token` above.
data "coder_parameter" "lab_sim_agent_token" {
  name         = "lab_sim_agent_token"
  display_name = "lab-sim Agent Token"
  description  = "Optional bearer token for the `lab-sim` MCP server, wired into .mcp.json as LAB_SIM_AGENT_TOKEN. Leave empty if lab-sim access is not needed."
  type         = "string"
  default      = ""
  mutable      = true
  order        = 3
}

# Issue #43 Step 5 (corrected): omnigent has no `--token` login flag — its
# "accounts" auth mode is username + password only (verified live against
# the real CLI's `_accounts_login()`: prompts for both, POSTs
# `/auth/login`). The real values are the shared first-admin account at
# OpenBao path `secret/devenv-cloud/omnigent/host-account` (see
# variables.tf's comment above `omnigent_server_url` for why this is a
# coder_parameter rather than a live OpenBao read). Left empty, the
# startup script skips both login and host registration entirely rather
# than fail the whole workspace boot on a missing credential — same
# "optional, default-empty, non-fatal" pattern as `lab_sim_agent_token`
# above.
data "coder_parameter" "omnigent_admin_username" {
  name         = "omnigent_admin_username"
  display_name = "Omnigent Admin Username"
  description  = "Username for the shared omnigent-server first-admin account (OpenBao secret/devenv-cloud/omnigent/host-account)."
  type         = "string"
  default      = "admin"
  mutable      = true
  order        = 4
}

data "coder_parameter" "omnigent_admin_password" {
  name         = "omnigent_admin_password"
  display_name = "Omnigent Admin Password"
  description  = "Password for the shared omnigent-server first-admin account (OpenBao secret/devenv-cloud/omnigent/host-account). Leave empty to skip omnigent host registration."
  type         = "string"
  default      = ""
  mutable      = true
  order        = 5
}

locals {
  # M4: JSON-RPC/Agent Host security-baseline settings. Kept in sync by hand
  # with the human-readable copy at repository root, `agent-host/settings.json`
  # — Coder template push only uploads this template directory, not the
  # repository root (same limitation already noted for the Dockerfile in
  # `workspace_image`'s description above), so it cannot be read in via
  # `file("../../agent-host/settings.json")`.
  agent_host_settings = {
    "chat.agent.sandbox.enabled" = true
    "chat.sessionSync.enabled"   = false
  }
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  # Real bug found live at E2E test time (T13): without an explicit `dir`,
  # Coder Agents' Chats API defaults a chat's working directory to $HOME
  # (/home/coder), NOT wherever the repo is cloned — so a .mcp.json
  # written to workspace_dir (/home/coder/project) was silently never
  # discovered (verified: the agent had no lab-sim tools available and
  # instead hallucinated a shell command). Setting `dir` here is what
  # makes MCP auto-discovery actually find the file. The base
  # `docker-workspace` template has this same gap but fixing it there is
  # out of scope for issue #13.
  dir = local.workspace_dir

  # Clone the repository (idempotent) and land the shell in the project
  # directory, per the M3 objective: "start in project directory".
  startup_script = <<-EOT
    set -e

    if [ ! -d "${local.workspace_dir}/.git" ]; then
      if [ -n "$GITHUB_TOKEN" ]; then
        cat > /tmp/git-askpass.sh <<'ASKPASS'
#!/bin/sh
echo "$GITHUB_TOKEN"
ASKPASS
        chmod +x /tmp/git-askpass.sh
        export GIT_ASKPASS=/tmp/git-askpass.sh
        export GIT_TERMINAL_PROMPT=0
      fi
      git clone "${local.repo_url}" "${local.workspace_dir}"
    fi

    echo 'cd ${local.workspace_dir}' >> ~/.bashrc

    # M4 (VS Code Agent Host + AHP): apply the sandbox/session-locality
    # settings the Agent Host and VS Code Remote read from
    # `.vscode/settings.json` in the opened folder. Only write it the first
    # time so a developer's own edits to these settings later are not
    # clobbered on every workspace start.
    if [ ! -f "${local.workspace_dir}/.vscode/settings.json" ]; then
      mkdir -p "${local.workspace_dir}/.vscode"
      cat > "${local.workspace_dir}/.vscode/settings.json" <<'VSCODE_SETTINGS'
${jsonencode(local.agent_host_settings)}
VSCODE_SETTINGS
    fi

    # M4: best-effort autostop relaxation for agent-capable workspaces. The
    # Coder CLI is not guaranteed to be present/authenticated for the
    # workspace's own token inside every image, so this is deliberately
    # non-fatal (`|| true`) and documented as a known limitation in
    # docs/milestone-reports/M4-agent-host.md rather than relied upon.
    if [ "${data.coder_parameter.agent_capable.value}" = "true" ] && command -v coder >/dev/null 2>&1; then
      coder schedule stop "$(hostname)" --disable-ttl || true
    fi

    # M9 (Agent/Harness Plane): copy/symlink the versioned `srt`
    # (Anthropic Sandbox Runtime) settings template into the persistent
    # home volume on first boot only, so a developer's own later edits to
    # ~/.srt-settings.json are not clobbered on every workspace start (same
    # pattern as .vscode/settings.json above).
    if [ ! -f ~/.srt-settings.json ]; then
      if [ -f "${local.workspace_dir}/agent-host/srt-settings.json" ]; then
        cp "${local.workspace_dir}/agent-host/srt-settings.json" ~/.srt-settings.json
      elif [ -f /etc/cade/srt-settings.default.json ]; then
        cp /etc/cade/srt-settings.default.json ~/.srt-settings.json
      fi
    fi

    # M9: wrap the `opencode`/`pi` agent harnesses in `srt` by default, and
    # persist tmux config (if any) on the same home volume rather than the
    # ephemeral container filesystem.
    if ! grep -q "alias opencode=" ~/.bashrc 2>/dev/null; then
      cat >> ~/.bashrc <<'BASHRC_ALIASES'
alias opencode='srt opencode --'
alias pi='srt pi --'
BASHRC_ALIASES
    fi

    # Issue #13 Task 7: `boundary` network-isolation CLI aliases, first-boot
    # only and non-clobbering, same idempotent style as the `srt` aliases
    # above. This wraps agent harnesses so their outbound network access can
    # be constrained/audited via the Task 8 allow-list config written below.
    if ! grep -q "alias boundary-opencode=" ~/.bashrc 2>/dev/null; then
      cat >> ~/.bashrc <<'BOUNDARY_ALIASES'
alias boundary-opencode='boundary --config ~/.boundary/config.yaml -- srt opencode --'
alias boundary-pi='boundary --config ~/.boundary/config.yaml -- srt pi --'
BOUNDARY_ALIASES
    fi

    # Issue #13 Task 8: `boundary` egress allowlist, first-boot only and
    # non-clobbering, same idempotent pattern as ~/.srt-settings.json
    # above. The template directory doesn't have the repo-root
    # `governance/boundary/config.yaml` available at `terraform push`
    # time (Coder template push only uploads this directory, not the
    # repo root — same limitation already noted for `agent_host_settings`
    # above), so the content is embedded inline here and MUST be kept in
    # sync by hand with `governance/boundary/config.yaml`.
    #
    # jail_type: landjail (not nsjail) — verified live at E2E test time
    # (T9) against a real built cade/agent-workspace:latest image:
    # nsjail fails in this environment with the same unprivileged-userns
    # restriction AGENTS.md already documents for `srt`'s
    # `bwrap --unshare-user` ("setpriv: apply capabilities: Operation not
    # permitted"). landjail worked: a real `curl` to an allowlisted
    # domain returned 200, a non-allowlisted domain returned 403 from
    # boundary's own proxy.
    if [ ! -f ~/.boundary/config.yaml ]; then
      mkdir -p ~/.boundary
      cat > ~/.boundary/config.yaml <<'BOUNDARY_CONFIG'
allowlist:
  - "domain=github.com"
  - "domain=*.github.com"
  - "domain=api.openai.com"
  - "domain=registry.npmjs.org"
  - "domain=pypi.org"
  - "domain=files.pythonhosted.org"
jail_type: landjail
log_dir: /tmp/boundary_logs
proxy_port: 8087
log_level: warn
BOUNDARY_CONFIG
    fi

    # Issue #13 Task 8b: `.mcp.json` wiring for the `lab-sim` MCP server,
    # first-boot only and non-clobbering (same pattern as above). Note
    # the `$${LAB_SIM_AGENT_TOKEN}` double-dollar escaping below — this
    # heredoc is inside a Terraform `<<-EOT` string, so a single `$` would
    # be consumed by Terraform's own interpolation; `$$` emits a literal
    # `$` into the rendered startup script for the shell to expand at
    # container runtime (same escaping already used for `$${HOME}` in the
    # "Home Disk" metadata script below).
    if [ ! -f "${local.workspace_dir}/.mcp.json" ]; then
      cat > "${local.workspace_dir}/.mcp.json" <<MCP_JSON
{
  "mcpServers": {
    "lab-sim": {
      "type": "http",
      "url": "http://lab-sim:8300/mcp/",
      "headers": { "Authorization": "Bearer $${LAB_SIM_AGENT_TOKEN}" }
    }
  }
}
MCP_JSON
    fi

    # Issue #43 Step 5: PATH shim so the omnigent-spawned harness resolves
    # `opencode` the same way as the interactive alias above. The omnigent
    # CLI's opencode-native runner spawns its native server by the literal
    # command name "opencode" (verified against omnigent-ai/omnigent's own
    # `_run_with_remote_server`, which passes `native_command="opencode"`
    # -- resolved via a PATH lookup at spawn time, not a hardcoded absolute
    # path or config field), so a directory prepended to PATH ahead of the
    # real binary at /usr/local/bin/opencode is the correct, minimal
    # integration point -- no omnigent-side config change needed.
    #
    # "srt" mode (default): the shim execs `srt /usr/local/bin/opencode --`,
    # identical in effect to the interactive `alias opencode='srt opencode
    # --'` above, so there is only one (sandboxed) code path for actually
    # running agent turns -- omnigent never gets a second, unsandboxed way
    # to spawn opencode. IMPORTANT (live E2E finding): pass srt the
    # ABSOLUTE path, never the bare word "opencode" -- srt's own internal
    # spawn of the target program re-resolves a bare command name via
    # PATH too, and since this shim's directory is itself prepended onto
    # PATH (see below), a bare "opencode" argument resolves right back to
    # THIS SAME SHIM, causing srt to recursively re-invoke itself (a
    # second nested bwrap sandbox launching a third, etc.), which
    # manifested as `Error: listen EPERM: operation not permitted
    # /tmp/claude/srt-mux-2-0.sock` (both nested sandbox layers landing on
    # the same deterministic pid-in-namespace-derived mux socket path).
    # Reproduced live in a real Coder workspace and confirmed by isolation
    # (identical failure with `srt opencode --`, reliably fixed by
    # `srt /usr/local/bin/opencode --`, with PATH held constant across
    # both) -- this was a bug in this shim's own design, not in srt.
    # "plain" mode: the shim execs the real binary directly. Verification
    # only; must never be the default (enforced by
    # `variable.omnigent_sandbox_mode`'s validation + its own default).
    mkdir -p ~/.omnigent-bin
    cat > ~/.omnigent-bin/opencode <<'OMNIGENT_OPENCODE_SHIM'
#!/bin/sh
set -e
if [ "$OMNIGENT_SANDBOX_MODE" = "plain" ]; then
  exec /usr/local/bin/opencode "$@"
fi

# Issue #45 (Direction 4): srt's `bwrap --unshare-net` puts a sandboxed
# `opencode serve` in a private network namespace, so its loopback port is
# unreachable from the unsandboxed omnigent runner polling
# http://127.0.0.1:<port> from outside the sandbox -- reproduced live in
# Issue #45's own investigation. Verified live fix (Issue #45, "Direction 4"
# comment): a Unix socket created inside the sandbox is still a filesystem
# object under the shared /tmp bind-mount, so it (unlike TCP) IS reachable
# from outside -- bridge the sandboxed TCP port to a Unix socket in here,
# and bridge that same Unix socket back to the identical TCP port from
# OUTSIDE the sandbox via the bridge-watchdog started in startup_script
# below. Only applies to a `serve --port <N>` invocation (omnigent's
# opencode-native harness's long-lived orchestration server) -- every other
# invocation (interactive attach, etc.) is unaffected.
is_serve=""
port=""
prev=""
for arg in "$@"; do
  if [ "$arg" = "serve" ]; then
    is_serve=1
  fi
  case "$prev" in
  --port)
    port="$arg"
    ;;
  esac
  case "$arg" in
  --port=*)
    port="$${arg#--port=}"
    ;;
  esac
  prev="$arg"
done

if [ -n "$is_serve" ] && [ -n "$port" ]; then
  # Stale-socket removal happens OUTSIDE srt, in this plain shell, before
  # srt ever starts -- /tmp is a shared bind-mount (see Issue #45 evidence
  # point 1), so this is safe/effective here, and a leftover socket file
  # from a prior session would otherwise make socat's UNIX-LISTEN below
  # fail with "Address already in use" inside the sandbox.
  rm -f "/tmp/opencode-bridge-$port.sock"
  # `srt -c "..."` runs the whole quoted string as ONE shell command inside
  # the sandbox, so both the bridge listener and the real server must be
  # started here, backgrounding the former and `exec`ing the latter so the
  # server (not the shell) becomes srt's actual foreground/PID-1-under-srt
  # process. `$*` (not "$@") is intentional here: it re-joins the shim's
  # own original arguments into the single string `srt -c` expects -- same
  # trade-off already accepted by the shim's own comments elsewhere in this
  # file (no embedded spaces expected in omnigent's own `serve --hostname
  # 127.0.0.1 --port <N>` invocation).
  exec srt -c "socat UNIX-LISTEN:/tmp/opencode-bridge-$port.sock,fork,reuseaddr TCP:127.0.0.1:$port & exec /usr/local/bin/opencode $*"
fi

exec srt /usr/local/bin/opencode -- "$@"
OMNIGENT_OPENCODE_SHIM
    chmod +x ~/.omnigent-bin/opencode
    if ! grep -q '.omnigent-bin' ~/.bashrc 2>/dev/null; then
      echo 'export PATH="$HOME/.omnigent-bin:$PATH"' >> ~/.bashrc
    fi
    # Issue #43 (live E2E finding): the .bashrc line above only helps a
    # FUTURE interactive shell -- it does NOT apply to the rest of THIS
    # startup_script invocation (coder_agent runs it via a non-interactive
    # `sh -c`, which never sources ~/.bashrc), and PATH is one of the vars
    # omnigent's daemon-spawn env allowlist DOES forward verbatim (see the
    # OMNIGENT_RUNNER_ENV_PASSTHROUGH comment on coder_agent.env below) --
    # so `omnigent host --background` below was inheriting the ORIGINAL
    # PATH with no ~/.omnigent-bin in it, and the omnigent-spawned
    # opencode-native runner (which resolves the literal command name
    # "opencode" via a plain PATH lookup) landed on the real
    # /usr/local/bin/opencode binary directly, completely bypassing the
    # shim and its srt wrapping. Reproduced live: `ps aux` inside a real
    # Coder-created workspace showed `opencode serve ...` running with no
    # bwrap/srt anywhere in its process tree. Export it into the CURRENT
    # script's own environment too, not just future shells.
    export PATH="$HOME/.omnigent-bin:$PATH"

    # Issue #45 (Direction 4): outside-sandbox half of the reverse
    # Unix-socket bridge -- pairs with the ~/.omnigent-bin/opencode shim
    # above, which starts (inside srt) a `socat UNIX-LISTEN:<sock>
    # TCP:127.0.0.1:<port>` bridge for any `opencode serve --port <N>`
    # invocation. This watchdog runs OUTSIDE the sandbox (plain container
    # namespace) and mirrors that bridge in the other direction --
    # `socat TCP-LISTEN:<port> UNIX-CONNECT:<sock>` -- so the unsandboxed
    # omnigent runner can reach 127.0.0.1:<port> exactly as if `opencode
    # serve` were not network-namespace-isolated at all, without weakening
    # srt's actual filesystem/process sandboxing. See Issue #45's
    # "Direction 4" comment for the full live-verified design/evidence.
    #
    # Written unconditionally (always overwritten, not just-if-missing) on
    # every boot, unlike the user-editable config blocks elsewhere in this
    # script (e.g. .vscode/settings.json) -- this file is never meant to be
    # hand-edited, so there's nothing to preserve across a rewrite.
    mkdir -p ~/.omnigent-bin
    cat > ~/.omnigent-bin/bridge-watchdog.sh <<'BRIDGE_WATCHDOG'
#!/bin/sh
# Polls for opencode-bridge-<N>.sock files created by the srt-side shim and
# keeps a matching plain (unsandboxed) socat TCP<->UNIX bridge running for
# each one, reaping the bridge process once its socket disappears (the
# owning srt session ended). Runs forever; intended to be started once as a
# detached background process by startup_script, guarded against
# double-spawning on a workspace restart (see the pgrep check below it).
while true; do
  for sock in /tmp/opencode-bridge-*.sock; do
    [ -e "$sock" ] || continue
    base=$(basename "$sock" .sock)
    port="$${base#opencode-bridge-}"
    pidfile="/tmp/opencode-bridge-$port.pid"
    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
      continue
    fi
    socat TCP-LISTEN:"$port",fork,reuseaddr UNIX-CONNECT:"$sock",retry &
    echo $! >"$pidfile"
  done

  for pidfile in /tmp/opencode-bridge-*.pid; do
    [ -e "$pidfile" ] || continue
    base=$(basename "$pidfile" .pid)
    port="$${base#opencode-bridge-}"
    sock="/tmp/opencode-bridge-$port.sock"
    # Issue #45 Step 3 (live E2E finding): a Unix socket special file is
    # NOT automatically removed from disk when its listening process
    # exits -- `[ -e "$sock" ]` alone stays true forever after the
    # sandboxed srt session that created it has already ended, so this
    # reaping check never fired and the outside bridge (and its stale
    # pidfile/socket) leaked indefinitely. Reproduced live: killed the
    # sandboxed `opencode serve`/socat pair, the .sock file remained on
    # disk unchanged. Fixed by actively probing for a live listener
    # (`socat -u OPEN:/dev/null UNIX-CONNECT:"$sock"` connects then
    # immediately EOFs; a dead/no-listener socket fails fast with
    # "Connection refused", confirmed live) instead of trusting mere
    # file existence.
    if [ ! -e "$sock" ] || ! socat -u OPEN:/dev/null UNIX-CONNECT:"$sock" >/dev/null 2>&1; then
      kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
      rm -f "$pidfile" "$sock"
    fi
  done

  sleep 1
done
BRIDGE_WATCHDOG
    chmod +x ~/.omnigent-bin/bridge-watchdog.sh

    # Idempotent start: a PID-file + `kill -0` check, NOT `pgrep -f
    # 'bridge-watchdog.sh'` -- verified live (Issue #45 Step 3) that a
    # `pgrep -f` string match self-matches the CURRENTLY RUNNING
    # startup_script shell process itself, because `coder_agent` executes
    # this entire startup_script as a single `sh -c "<script text>"`
    # invocation, and that script's own text (this very comment, the
    # heredoc above, etc.) contains the literal substring
    # "bridge-watchdog.sh" -- so the check always found a false-positive
    # "match" against its own already-running parent shell and silently
    # skipped starting the watchdog every single boot. A PID file avoids
    # any text-matching self-reference entirely; it's also safe against
    # the "stale file from a no-longer-existing container" case the prior
    # comment worried about, since /tmp is NOT on the persistent home
    # volume -- a freshly (re)created container always starts with an
    # empty /tmp, so a leftover PID file can only ever refer to a process
    # from THIS SAME still-running container.
    if [ ! -f /tmp/omnigent-bridge-watchdog.pid ] || ! kill -0 "$(cat /tmp/omnigent-bridge-watchdog.pid 2>/dev/null)" 2>/dev/null; then
      nohup ~/.omnigent-bin/bridge-watchdog.sh >/tmp/omnigent-bridge-watchdog.log 2>&1 &
      echo $! >/tmp/omnigent-bridge-watchdog.pid
    fi

    # Issue #43 Step 5 (corrected): authenticate against omnigent-server's
    # "accounts" auth mode by replicating the real CLI's own
    # `_accounts_login()` code path exactly (verified live against the
    # installed omnigent==0.11.0 package: `omnigent login`/`omnigent host`
    # have no --token/non-interactive credential flag at all) — POST
    # /auth/login with {username, password}, then persist the session via
    # `omnigent.cli_auth.store_token(...)`, using the omnigent package's
    # own venv Python so this can never drift from the real persisted-file
    # format if the CLI changes. Re-authenticates on every workspace start
    # rather than checking ~/.omnigent/auth_tokens.json for an existing
    # non-expired entry first — simpler, and one extra login call per
    # workspace start is cheap; skipping it opportunistically is a
    # possible future optimization, not required for correctness.
    if [ -n "$${OMNIGENT_ADMIN_PASSWORD}" ] && command -v /opt/omnigent-venv/bin/python3 >/dev/null 2>&1; then
      /opt/omnigent-venv/bin/python3 <<'OMNIGENT_LOGIN_PY' || true
import os
import time

import httpx

from omnigent.cli_auth import store_token

server = os.environ["OMNIGENT_SERVER_URL"]
username = os.environ["OMNIGENT_ADMIN_USERNAME"]
password = os.environ["OMNIGENT_ADMIN_PASSWORD"]

resp = httpx.post(
    f"{server}/auth/login",
    json={"username": username, "password": password},
    timeout=10.0,
)
resp.raise_for_status()
body = resp.json()
store_token(
    server_url=server,
    token=body["token"],
    user_id=body["user"]["id"],
    expires_at=time.time() + body.get("expires_in", 8 * 3600),
    refresh_token=body.get("refresh_token"),
)
print(f"omnigent: logged in as {body['user']['id']}")
OMNIGENT_LOGIN_PY

      # Issue #43 Step 5 (corrected AGAIN, live E2E finding): the
      # OMNIGENT_HOST_ID/OMNIGENT_HOST_NAME env var pair does NOT reach the
      # actual `--background` daemon process. Verified live against the
      # real omnigent==0.11.0 source (`omnigent.cli._build_host_daemon_env`):
      # a background/remote host daemon is spawned via `subprocess.Popen`
      # with a strict environment ALLOWLIST (process essentials, TLS trust,
      # proxy vars, Databricks auth) that does NOT include OMNIGENT_HOST_ID/
      # OMNIGENT_HOST_NAME at all — those two vars are silently dropped
      # before the daemon subprocess ever sees them, so `omnigent host`
      # falls back to a random uuid4 + the container hostname every time,
      # never the intended identity. Reproduced live: registered host_id
      # and name both did NOT match what was set via env vars.
      #
      # The real, verified-working mechanism instead: `omnigent host`
      # honors a pre-existing `host:` section in ~/.omnigent/config.yaml
      # (read by `omnigent.host.identity.load_or_create_host_identity`
      # inside the daemon subprocess itself, no env-var relay needed) if
      # BOTH `host_id` and `name` are already present — write it directly,
      # first-boot only (idempotent, same pattern as the srt-settings/MCP
      # config blocks above), before ever invoking `omnigent host`. This
      # also has a robustness upside over the (broken) env-var approach:
      # ~/.omnigent lives on the persistent home volume, so the identity
      # written here survives `coder stop`/`start` for free, with no
      # reliance on Coder re-passing the same derived value on every boot.
       if [ ! -f ~/.omnigent/config.yaml ]; then
         mkdir -p ~/.omnigent
         cat > ~/.omnigent/config.yaml <<OMNIGENT_HOST_IDENTITY
host:
  host_id: ${local.omnigent_host_id}
  name: ${local.omnigent_host_name}
OMNIGENT_HOST_IDENTITY
       fi

       # Issue #82: work around Omnigent's opencode-native readiness check
       # (omnigent/onboarding/opencode_auth.py) reporting a false-positive
       # "needs-auth" badge. That check only recognizes a stored auth.json
       # provider entry or a provider env var as "configured" — it has no
       # concept of OpenCode's free, credential-less default "Zen" model
       # (opencode/big-pickle). Three unsafe variants were tried and
       # rejected before landing on this one (see docs/ai-coder.md's
       # Omnigent section for the full live evidence):
       #   1. A dummy OPENAI_API_KEY/auth.json entry with NO model pin
       #      silently redirects OpenCode's own default-model selection
       #      away from big-pickle to whatever provider now looks
       #      "configured" (reproduced: `build · gpt-5.3-chat-latest` ->
       #      `Incorrect API key provided`), breaking this repo's own
       #      documented Journey 1 default-model behavior.
       #   2. A dummy OPENAI_API_KEY env var (even with the model pin)
       #      never reaches the readiness check at all in this
       #      configuration: our templates always invoke
       #      `omnigent host "$OMNIGENT_SERVER_URL" --background
       #      --non-interactive` (remote-daemon mode), and omnigent's own
       #      `omnigent/cli.py::_build_host_daemon_env()` deliberately
       #      excludes provider secrets (OPENAI_API_KEY/ANTHROPIC_API_KEY/
       #      etc.) from the daemon's environment in remote mode (only
       #      LOCAL mode, server_url unset, forwards them) — by design, so
       #      a shared remote server doesn't inherit the workspace owner's
       #      provider secrets. Confirmed live via
       #      /proc/<daemon-pid>/environ showing the var simply absent.
       #   3. Routing around (2) via a different env-var channel is not
       #      viable either — the daemon-spawn allowlist is intentional
       #      upstream security design, not a bug, and must not be
       #      defeated.
       # What DOES work, verified live end-to-end (opencode run still uses
       # big-pickle; Omnigent's /v1/hosts reports opencode-native: true):
       #   a. Pin the default model explicitly in
       #      ~/.config/opencode/opencode.jsonc — this overrides
       #      OpenCode's own credential-presence-based default-model
       #      selection regardless of what other (dummy) credentials
       #      exist, so big-pickle stays active no matter what.
       #   b. Write a dummy provider entry directly to the FILE
       #      ~/.local/share/opencode/auth.json (never an env var) —
       #      omnigent's `_stored_providers()` re-reads this file fresh
       #      from disk on every readiness check, entirely independent of
       #      the daemon's own filtered/stale environment; this is the
       #      only channel that actually reaches the check in
       #      remote-daemon mode.
       # Both writes are purely cosmetic (satisfy the badge only) and
       # MUST NEVER be treated as configuring a real OpenCode provider —
       # a user who wants a real, working provider should use
       # `omnigent setup`/`opencode auth login` normally. Both are
       # idempotent and non-destructive: the model pin is only written if
       # the config file doesn't already exist (never clobber a
       # user-customized config, matching this template's existing
       # copy-once guard pattern for srt-settings.json), and the dummy
       # auth.json entry is only written if auth.json doesn't already
       # exist or has zero real entries (never overwrite a genuine
       # `opencode auth login` credential).
       mkdir -p ~/.config/opencode
       if [ ! -f ~/.config/opencode/opencode.jsonc ]; then
         cat > ~/.config/opencode/opencode.jsonc <<'OMNIGENT_OPENCODE_MODEL_PIN'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode/big-pickle"
}
OMNIGENT_OPENCODE_MODEL_PIN
       fi

       mkdir -p ~/.local/share/opencode
       omnigent_auth_json=~/.local/share/opencode/auth.json
       if [ ! -s "$omnigent_auth_json" ] || [ "$(cat "$omnigent_auth_json")" = "{}" ]; then
         cat > "$omnigent_auth_json" <<'OMNIGENT_DUMMY_AUTH'
{"openai": {"type": "api", "key": "sk-dummy-placeholder"}}
OMNIGENT_DUMMY_AUTH
       fi

       # `--background` spawns the daemon detached and returns immediately
       # (reusing a healthy daemon if already up), so no trailing shell `&`
       # is needed here.
       omnigent host "$${OMNIGENT_SERVER_URL}" --background --non-interactive >/tmp/omnigent-host.log 2>&1 || true
     fi
   EOT

  env = {
    GIT_AUTHOR_NAME         = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL        = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME      = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL     = "${data.coder_workspace_owner.me.email}"
    GITHUB_TOKEN            = try(coalesce(data.coder_external_auth.github.access_token, data.coder_parameter.github_token.value), "")
    LAB_SIM_AGENT_TOKEN     = data.coder_parameter.lab_sim_agent_token.value
    OMNIGENT_SERVER_URL     = var.omnigent_server_url
    OMNIGENT_ADMIN_USERNAME = data.coder_parameter.omnigent_admin_username.value
    OMNIGENT_ADMIN_PASSWORD = data.coder_parameter.omnigent_admin_password.value
    OMNIGENT_SANDBOX_MODE   = var.omnigent_sandbox_mode
    # Issue #43: OMNIGENT_SANDBOX_MODE is NOT in omnigent's own daemon/runner
    # environment allowlist (`omnigent.host.connect._RUNNER_ENV_ALLOWLIST` +
    # its prefixes LC_/MLFLOW_/OTEL_/OMNIGENT_OTEL_), so it is silently
    # dropped before reaching the runner subprocess that actually spawns
    # `opencode` via the ~/.omnigent-bin PATH shim — the same class of
    # silently-filtered-env-var bug already hit with OMNIGENT_HOST_ID/NAME
    # (see AGENTS.md Lessons Learned). Without this passthrough the shim
    # sees an unset value: harmless for the shipped "srt" default (the shim
    # falls through to `srt opencode --`, i.e. it fails SAFE), but it makes
    # "plain" mode unreachable through the real omnigent daemon path, which
    # is exactly the Stage A verification checkpoint. OMNIGENT_RUNNER_ENV_PASSTHROUGH
    # is omnigent's own documented mechanism for this (a comma-separated list
    # of extra var names to forward) and IS itself allowlisted.
    OMNIGENT_RUNNER_ENV_PASSTHROUGH = "OMNIGENT_SANDBOX_MODE"
    # Coder Agents runs the AI loop in the control plane; this workspace
    # intentionally never receives an LLM provider API key.
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "2_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }
}

# VS Code Web / code-server access to the workspace, plus the SSH endpoint
# that scripts/configure-coder-ssh.sh (M4) relies on to reach the Agent Host.
module "code-server" {
  count   = data.coder_workspace.me.start_count
  source  = "registry.coder.com/coder/code-server/coder"
  version = "~> 1.0"

  agent_id = coder_agent.main.id
  folder   = local.workspace_dir
  order    = 1
}

# Issue #43 Step 6: dashboard tile linking out to the omnigent chat UI.
# `external = true` is the correct mechanism here (verified: no iframe
# embedding exists for `coder_app` in this Coder version; Coder's own
# Zed/VS Code Desktop/JetBrains Gateway reference examples all use this
# same external-link pattern for a tool with no in-Coder embedded UI).
resource "coder_app" "omnigent" {
  agent_id     = coder_agent.main.id
  slug         = "omnigent"
  display_name = "Omnigent Chat"
  # Issue #47: Omnigent's own favicon instead of Coder's generic
  # /icon/widgets.svg. NOTE, verified live against the real Coder DB schema
  # (`workspace_apps.icon` is `character varying(256)`): the issue's own
  # recommended approach (embed the real favicon.svg -- 13.8KB raw, ~18.4KB
  # base64 -- as a self-contained `data:` URI via filebase64()) is
  # infeasible; `coder templates push` fails outright with `pq: value too
  # long for type character varying(256)` for ANY encoding of the real
  # asset (SVG or a rasterized PNG down to 8x8px still needs 500+ chars).
  # A real copy of the asset is kept at assets/omnigent-icon.svg for
  # provenance/a future fix (e.g. if Coder ever raises this column limit,
  # or serves template-bundled assets directly) -- see assets/README.md.
  # Using `omnigent_public_url` here instead introduces no *new* runtime
  # dependency: this coder_app is `external = true`, so the browser must
  # already reach `omnigent_public_url` directly to use the app at all;
  # the icon fetch shares that exact same, already-required reachability.
  icon     = "${var.omnigent_public_url}/favicon.svg"
  external = true
  # Uses omnigent_public_url (browser-reachable loopback), NOT
  # omnigent_server_url (internal compose DNS name used by the startup
  # script's own login/registration calls) — see variables.tf.
  #
  # The `?host=` query param is currently INERT: omnigent's shipped web UI
  # ignores unrecognized query params and always lands on New Chat. This is
  # intentional, forward-compatible plumbing pending upstream deep-link
  # support (omnigent-ai/omnigent#5881) — do not "fix" this later without
  # first checking whether that PR has merged and changed the UI's param
  # handling.
  url = "${var.omnigent_public_url}/?host=${local.omnigent_host_name}"
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"

  # Protect the volume from being deleted due to changes in attributes.
  # Per AGENTS.md's documented lesson, `ignore_changes = all` alone does
  # NOT survive `coder delete` — the volume only survives stop/start because
  # `docker_container.volumes` below references it by its fixed `name`
  # string, not only via the Terraform resource reference.
  lifecycle {
    ignore_changes = all
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = var.workspace_image
  name  = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"

  hostname   = data.coder_workspace.me.name
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  # Issue #13 Task 8b: attach to the `platform-workspaces` Docker network
  # (defined in the repo-root compose.yaml) so the workspace container can
  # resolve/reach `lab-sim` by its compose service name. Neither
  # `docker-workspace` nor `embedded-linux` templates currently attach to
  # this network (verified: no `networks_advanced` block in either), so
  # this is a new addition here, not an inherited/duplicated one.
  networks_advanced {
    name = "platform-workspaces"
  }

  # Issue #23: scoped seccomp + AppArmor profiles that permit `bwrap`
  # (used by `srt`, which wraps `opencode`/`pi`, see the alias below) to
  # create an unprivileged user namespace and its initial rslave remount,
  # without widening the container's confinement any further than that
  # (no `privileged = true`, no `apparmor=unconfined`/`seccomp=unconfined`).
  # The seccomp value is the *content* of the profile (via `file()`), not a
  # path -- Docker's API accepts "seccomp=<json>" directly, which avoids any
  # dependency on this path still existing wherever `terraform apply`
  # actually runs a real `coder templates push` from (see AGENTS.md's
  # documented "templates push only uploads the template dir" gotcha).
  # PREREQUISITE, not a soft fallback: `apparmor=cade-bwrap-workspace`
  # requires that exact profile to already be loaded on the Docker host via
  # `scripts/load-security-profiles.sh` (wired into `make doctor`/`make up`,
  # not executed by this Terraform). Verified live 2026-08-30: referencing
  # an unloaded/unknown AppArmor profile name is a HARD `docker run` failure
  # ("unable to apply apparmor profile"), not a silent fallback to
  # `docker-default` -- run the load script (or `make doctor`) at least once
  # on this host before `make templates-push`/`coder create` against a
  # template that references this profile, or every workspace create will
  # fail outright.
  # Issue #40: Docker's `systempaths` masking (bind-mounting read-only
  # decoys over sensitive /proc and /sys paths, e.g. /proc/kcore,
  # /proc/keys, /sys/firmware) is a *third*, separate Docker confinement
  # layer, independent of seccomp/AppArmor/capabilities -- it was found
  # live to also block bwrap's nested fresh-procfs mount, with the exact
  # same "Can't mount proc" error persisting even under fully-unconfined
  # seccomp+AppArmor and `--cap-add SYS_ADMIN`, only resolved by
  # `--privileged` or this flag specifically. Disabling it here is NOT a
  # security regression: this profile's own AppArmor rules (inherited
  # from upstream `docker-default`) already independently `deny` access
  # to every one of the exact same sensitive paths `systempaths` masks
  # (see `deny @{PROC}/kcore rwklx,` / `deny /sys/firmware/** rwklx,`
  # etc. in the AppArmor profile) -- both mechanisms enforce the same
  # boundary redundantly; disabling one while the other remains active
  # does not widen the container's actual attack surface. Verified live:
  # `systempaths=unconfined` alone (no extra `cap-add`, no
  # `--privileged`) combined with the scoped seccomp+AppArmor profiles
  # below was sufficient for a real `srt opencode`/`srt pi` completion.
  security_opts = [
    "seccomp=${file("${path.module}/security/seccomp-bwrap-userns.json")}",
    "apparmor=cade-bwrap-workspace",
    "systempaths=unconfined",
  ]

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}
