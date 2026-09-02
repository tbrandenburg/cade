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
  # Issue #75 (ported from agent-workspace/main.tf's Issue #43 Step 5):
  # legible per-workspace omnigent host name/id, only meaningful when
  # enable_omnigent=true — see that file's comment for the full rationale
  # on why host_id/name are written into ~/.omnigent/config.yaml rather
  # than passed via OMNIGENT_HOST_ID/OMNIGENT_HOST_NAME env vars (silently
  # dropped by omnigent's own daemon-spawn allowlist).
  omnigent_host_name = "${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
  omnigent_host_id   = md5(data.coder_workspace.me.id)
}

provider "docker" {
  host = var.docker_socket != "" ? var.docker_socket : null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# Workspace app tiers (see coder/templates/docker-workspace/README.md and
# .agents/skills/coder-app-tile/SKILL.md for the full convention):
#
# Tier 1 — core, always on, no coder_parameter:
#   - VS Code Web (module.code-server, below)
#   - SSH / Web Terminal (Coder platform built-in, not defined here)
## Tier 2 — optional, creation-time coder_parameter (bool, default "false"):
#   - temporal_owned  -> coder_app.temporal
#   - enable_jupyter  -> coder_script.jupyter + coder_app.jupyter
#   - enable_nodered  -> coder_script.nodered + coder_app.nodered
#   - enable_omnigent -> startup_script block + coder_app.omnigent (Issue #75)
#
# Tier 3 — optional, post-instantiation (no recreate needed):
#   scripts/set-workspace-parameter.sh <owner>/<ws> <param_name> <value>
#   (set-workspace-temporal-tile.sh / -jupyter.sh / -nodered.sh are thin,
#   byte-compatible wrappers around this one generic script)
#
# Any NEW opt-in app MUST follow Tier 2 (bool coder_parameter, default
# false, count-gated coder_app/coder_script pair) — it then gets Tier 3
# for free via scripts/set-workspace-parameter.sh with no new script.

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

# M4 (VS Code Agent Host + AHP): workspaces intended to run a long-lived
# Agent Host session need to survive longer than the default idle-autostop
# window, since Coder's autostop/scheduling is driven by IDE/SSH/terminal
# activity and there is no confirmed guarantee that Agent Host activity
# alone counts toward idle detection (a workspace could autostop while an
# agent is still working with no editor attached). This parameter only
# widens/disables the autostop window at workspace-create time (below) —
# it is a documented interim workaround, not a real workspace lease. See
# docs/milestone-reports/M4-agent-host.md "Known limitation".
data "coder_parameter" "agent_capable" {
  name         = "agent_capable"
  display_name = "Agent-capable (disable aggressive autostop)"
  description  = "Set true for workspaces expected to run long Agent Host sessions unattended. Human-only workspaces should leave this false and keep the default autostop."
  type         = "bool"
  default      = "false"
  mutable      = true
  order        = 2
}

# Issue #50 §10: gates a dashboard tile linking this workspace to the
# Temporal Workflows UI (see coder_app.temporal below), filtered to the
# workflows this workspace itself is associated with. Only Temporal's own
# `PersistentWorkspaceBuildWorkflow` (temporal/src/demo/workspace_activity.py)
# should ever set this true when creating a `tw-*` workspace — an explicit
# boolean parameter is used instead of sniffing the workspace name prefix,
# so the gating is not silently coupled to a naming convention that could
# change independently of this template.
data "coder_parameter" "temporal_owned" {
  name         = "temporal_owned"
  display_name = "Temporal-owned workspace"
  description  = "Set true only for workspaces created/managed by Temporal (Issue #50) — adds a dashboard tile linking to the Temporal Workflows UI filtered to this workspace. Human-created workspaces should leave this false."
  type         = "bool"
  default      = "false"
  mutable      = true
  order        = 3
}

# Issue #60: independent, opt-in JupyterLab tile. Both `false` by default —
# zero behaviour change for existing workspaces. See coder_script.jupyter /
# coder_app.jupyter below for the full design rationale (in-workspace
# process, no separate login — guarded solely by Coder's own agent-proxy
# session auth).
data "coder_parameter" "enable_jupyter" {
  name         = "enable_jupyter"
  display_name = "Enable JupyterLab"
  description  = "Start JupyterLab in this workspace and show its dashboard tile. Notebooks live in /home/coder/project (persistent home volume). No separate login — access is guarded by Coder's own session auth."
  type         = "bool"
  default      = "false"
  mutable      = true
  order        = 4
}

# Issue #60: independent, opt-in Node-RED tile. See coder_script.nodered /
# coder_app.nodered below.
data "coder_parameter" "enable_nodered" {
  name         = "enable_nodered"
  display_name = "Enable Node-RED"
  description  = "Start Node-RED in this workspace and show its dashboard tile. Flows live in /home/coder/.node-red (persistent home volume). No separate login — access is guarded by Coder's own session auth."
  type         = "bool"
  default      = "false"
  mutable      = true
  order        = 5
}

# Issue #75: Tier-2 opt-in Omnigent Chat tile, ported from
# agent-workspace/main.tf's Tier-1 (always-on) omnigent integration
# (Issue #43/#45) — deliberately demoted to Tier 2 here per this
# template's own three-tier convention (see coder-app-tile/SKILL.md and
# AGENTS.md's "Workspace-app tiers" guideline): forcing every
# docker-workspace user through Omnigent login/registration at every
# workspace start would be unnecessary friction for this template's
# broader, non-agent-specialized audience, unlike agent-workspace which
# exists specifically for long-running Coder Agents sessions. `false` by
# default — zero behaviour change, no new container/network dependency,
# no login prompt, no extra startup-script latency for existing
# workspaces. Gates every Omnigent-related resource below (the startup
# script block, coder_app.omnigent, and the two credential parameters'
# practical relevance).
data "coder_parameter" "enable_omnigent" {
  name         = "enable_omnigent"
  display_name = "Enable Omnigent Chat"
  description  = "Start the omnigent host daemon in this workspace and show an \"Omnigent Chat\" dashboard tile linking to the shared omnigent-server UI. Requires omnigent-db/omnigent-server to be up (`docker compose up -d omnigent-db omnigent-server` + `make omnigent-bootstrap`) — see this template's README."
  type         = "bool"
  default      = "false"
  mutable      = true
  order        = 6
}

# Issue #75 (ported from agent-workspace/main.tf's Issue #43 Step 5): only
# meaningful when enable_omnigent=true — see that file's comment for the
# full rationale (shared omnigent-server first-admin account, OpenBao
# secret/devenv-cloud/omnigent/host-account; omnigent's "accounts" auth
# mode is username+password only, no bearer-token login flag).
data "coder_parameter" "omnigent_admin_username" {
  name         = "omnigent_admin_username"
  display_name = "Omnigent Admin Username"
  description  = "Username for the shared omnigent-server first-admin account (OpenBao secret/devenv-cloud/omnigent/host-account). Only used when enable_omnigent=true."
  type         = "string"
  default      = "admin"
  mutable      = true
  order        = 7
}

data "coder_parameter" "omnigent_admin_password" {
  name         = "omnigent_admin_password"
  display_name = "Omnigent Admin Password"
  description  = "Password for the shared omnigent-server first-admin account (OpenBao secret/devenv-cloud/omnigent/host-account). Leave empty to skip omnigent host registration entirely. Only used when enable_omnigent=true."
  type         = "string"
  default      = ""
  mutable      = true
  order        = 8
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

    # M4 / Issue #74: autostop relaxation for agent-capable workspaces
    # CANNOT be performed from inside the workspace container itself.
    # `$CODER_AGENT_TOKEN` (the only Coder credential ever present in this
    # container's env) authenticates the *workspace agent* protocol, not
    # the CLI/API user-session protocol `coder schedule stop` needs — it is
    # a bare UUID, not a `<key-id>:<secret>` API key, and the coderd API
    # rejects it outright ("Invalid API key format") for any
    # `/api/v2/...` call, including `PUT .../ttl`. There is also no
    # `coder_parameter`/env mechanism exposing a real user session token
    # to a running workspace by design (that would let any workspace
    # process act as its owner against the whole API). Live-confirmed
    # 2026-09 while fixing Issue #74: the previous `coder schedule stop
    # "$(hostname)" --disable-ttl` call failed on `--disable-ttl` (removed/
    # renamed in this deployment's v2.36.3 CLI) but would have *also*
    # failed on auth even with a correct flag/subcommand name — see
    # AGENTS.md's Issue #74 entry for the full evidence.
    #
    # The only real fix is to disable the TTL from OUTSIDE the workspace,
    # using a real, already-authenticated `coder` CLI session (exactly how
    # `coder schedule stop <owner>/<workspace> manual` was proven live to
    # actually clear `ttl_ms` via the Coder API). This is now
    # `scripts/verify-agent-capable-autostop.sh <owner>/<workspace>` —
    # idempotent, safe to re-run, and both applies and verifies the fix in
    # one call. Run it once right after `coder create ... --parameter
    # agent_capable=true`.
    #
    # This log line is intentionally ERROR-tagged and grep-able
    # (`grep AGENT_CAPABLE_TTL /tmp/coder-startup-script.log`) so a
    # future regression (e.g. someone re-adding a broken in-container
    # attempt) is caught by tooling instead of silently no-op'ing again.
    if [ "${data.coder_parameter.agent_capable.value}" = "true" ]; then
      echo "AGENT_CAPABLE_TTL: agent_capable=true — autostop is NOT disabled from inside the workspace (no valid API session token available here). Run 'scripts/verify-agent-capable-autostop.sh <owner>/<workspace>' from an authenticated host session to actually disable it." >> /tmp/coder-startup-script.log
    fi

    # M9 (Agent/Harness Plane): copy/symlink the versioned `srt`
    # (Anthropic Sandbox Runtime) settings template into the persistent
    # home volume on first boot only, so a developer's own later edits to
    # ~/.srt-settings.json are not clobbered on every workspace start (same
    # pattern as .vscode/settings.json above).
    if [ ! -f ~/.srt-settings.json ] && [ -f "${local.workspace_dir}/agent-host/srt-settings.json" ]; then
      cp "${local.workspace_dir}/agent-host/srt-settings.json" ~/.srt-settings.json
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

    # Issue #75: Omnigent host integration, ported verbatim (mechanism,
    # not just intent) from agent-workspace/main.tf's Issue #43/#45 block
    # — this template already wraps opencode/pi in srt (M9, same
    # `bwrap --unshare-net` sandboxing agent-workspace uses), so the
    # reverse-Unix-socket-bridge fix Issue #45 proved live for reaching a
    # srt-sandboxed `opencode serve` from the unsandboxed omnigent daemon
    # applies identically here. Entirely gated behind enable_omnigent —
    # a `false` value (the default) means NONE of this runs: no PATH
    # shim, no bridge/watchdog process, no login attempt, no
    # ~/.omnigent/config.yaml write, matching this template's Tier-2
    # "zero behaviour change when disabled" convention.
    if [ "${data.coder_parameter.enable_omnigent.value}" = "true" ]; then
      # Issue #43 Step 5: PATH shim so the omnigent-spawned harness
      # resolves `opencode` the same way as the interactive alias above.
      # See agent-workspace/main.tf's identical block for the full,
      # live-verified rationale (omnigent's opencode-native runner spawns
      # its native server by the literal command name "opencode", a PATH
      # lookup at spawn time) and the srt-recursion gotcha (always pass
      # srt the ABSOLUTE path, never the bare word "opencode", or srt
      # resolves its own target back through this same shim).
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
# http://127.0.0.1:<port> from outside the sandbox. Verified live fix
# (Issue #45, "Direction 4"): a Unix socket created inside the sandbox is
# still a filesystem object under the shared /tmp bind-mount, so it
# (unlike TCP) IS reachable from outside -- bridge the sandboxed TCP port
# to a Unix socket in here, and bridge that same Unix socket back to the
# identical TCP port from OUTSIDE the sandbox via the bridge-watchdog
# started below. Only applies to a `serve --port <N>` invocation
# (omnigent's opencode-native harness's long-lived orchestration server)
# -- every other invocation (interactive attach, etc.) is unaffected.
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
  rm -f "/tmp/opencode-bridge-$port.sock"
  exec srt -c "socat UNIX-LISTEN:/tmp/opencode-bridge-$port.sock,fork,reuseaddr TCP:127.0.0.1:$port & exec /usr/local/bin/opencode $*"
fi

exec srt /usr/local/bin/opencode -- "$@"
OMNIGENT_OPENCODE_SHIM
      chmod +x ~/.omnigent-bin/opencode
      if ! grep -q '.omnigent-bin' ~/.bashrc 2>/dev/null; then
        echo 'export PATH="$HOME/.omnigent-bin:$PATH"' >> ~/.bashrc
      fi
      # Issue #43 (live E2E finding): the .bashrc line above only helps a
      # FUTURE interactive shell -- `coder_agent` runs startup_script via a
      # non-interactive `sh -c`, which never sources ~/.bashrc. Export it
      # into the CURRENT script's own environment too.
      export PATH="$HOME/.omnigent-bin:$PATH"

      # Issue #45 (Direction 4): outside-sandbox half of the reverse
      # Unix-socket bridge -- pairs with the ~/.omnigent-bin/opencode shim
      # above. Written unconditionally (always overwritten) on every boot
      # -- this file is never meant to be hand-edited.
      mkdir -p ~/.omnigent-bin
      cat > ~/.omnigent-bin/bridge-watchdog.sh <<'BRIDGE_WATCHDOG'
#!/bin/sh
# Polls for opencode-bridge-<N>.sock files created by the srt-side shim and
# keeps a matching plain (unsandboxed) socat TCP<->UNIX bridge running for
# each one, reaping the bridge process once its socket disappears (the
# owning srt session ended).
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
    # Issue #45 Step 3 (live E2E finding): a dead Unix socket special file
    # is NOT automatically removed from disk -- probe for a live listener
    # (`socat -u OPEN:/dev/null UNIX-CONNECT:"$sock"`) instead of trusting
    # mere file existence.
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
      # 'bridge-watchdog.sh'` -- a `pgrep -f` string match self-matches
      # this currently-running startup_script shell process itself
      # (Issue #45 Step 3 lesson: the script's own text, including this
      # very comment, contains the literal substring "bridge-watchdog.sh").
      if [ ! -f /tmp/omnigent-bridge-watchdog.pid ] || ! kill -0 "$(cat /tmp/omnigent-bridge-watchdog.pid 2>/dev/null)" 2>/dev/null; then
        nohup ~/.omnigent-bin/bridge-watchdog.sh >/tmp/omnigent-bridge-watchdog.log 2>&1 &
        echo $! >/tmp/omnigent-bridge-watchdog.pid
      fi

      # Issue #43 Step 5 (corrected): authenticate against omnigent-server's
      # "accounts" auth mode by replicating the real CLI's own
      # `_accounts_login()` code path exactly (omnigent==0.11.0 has no
      # --token/non-interactive credential flag) — POST /auth/login with
      # {username, password}, then persist the session via
      # `omnigent.cli_auth.store_token(...)`. Re-authenticates on every
      # workspace start rather than checking for an existing non-expired
      # token first — simpler, and cheap.
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

        # Issue #43 Step 5 (corrected, live E2E finding): the
        # OMNIGENT_HOST_ID/OMNIGENT_HOST_NAME env var pair does NOT reach
        # the actual `--background` daemon process (silently dropped by
        # omnigent's own daemon-spawn environment allowlist). The real,
        # verified-working mechanism: `omnigent host` honors a pre-existing
        # `host:` section in ~/.omnigent/config.yaml if BOTH `host_id` and
        # `name` are already present — write it directly, first-boot only,
        # before ever invoking `omnigent host`. This file lives on the
        # persistent home volume, so identity survives `coder stop`/`start`.
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

        # `--background` spawns the daemon detached and returns
        # immediately (reusing a healthy daemon if already up).
        omnigent host "$${OMNIGENT_SERVER_URL}" --background --non-interactive >/tmp/omnigent-host.log 2>&1 || true
      fi
    fi
  EOT

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
    GITHUB_TOKEN        = data.coder_parameter.github_token.value
    # Issue #75: only consumed by the startup script when
    # enable_omnigent=true (see above) — harmless, always-set env vars
    # otherwise, same "cheap to always set, only acted on when gated"
    # pattern as agent-workspace/main.tf.
    OMNIGENT_SERVER_URL     = var.omnigent_server_url
    OMNIGENT_ADMIN_USERNAME = data.coder_parameter.omnigent_admin_username.value
    OMNIGENT_ADMIN_PASSWORD = data.coder_parameter.omnigent_admin_password.value
    OMNIGENT_SANDBOX_MODE   = var.omnigent_sandbox_mode
    # Issue #43: OMNIGENT_SANDBOX_MODE is NOT in omnigent's own daemon/
    # runner environment allowlist — OMNIGENT_RUNNER_ENV_PASSTHROUGH is
    # omnigent's own documented mechanism for forwarding extra var names,
    # and IS itself allowlisted. See agent-workspace/main.tf's identical
    # env block for the full rationale.
    OMNIGENT_RUNNER_ENV_PASSTHROUGH = "OMNIGENT_SANDBOX_MODE"
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

# Issue #50 §10: dashboard tile linking a Temporal-owned (`tw-*`) workspace
# to its own filtered Temporal Workflows UI view. `count` makes this a
# true no-op (zero resources) for the default/human-dev flow where
# `temporal_owned` stays false — this deliberately does not opportunistically
# render for every docker-workspace workspace, only ones Temporal itself
# creates via PersistentWorkspaceBuildWorkflow. `external = true` is
# required here for the same reason as coder_app.omnigent in
# agent-workspace/main.tf: no iframe/embedded-UI mechanism exists for
# coder_app in this Coder version. Unlike that omnigent tile, this icon is
# referenced directly by URL (no `data:` URI needed) since temporal-ui
# already serves a real, verified-decodable favicon.ico over plain HTTP —
# no `workspace_apps.icon` varchar(256) column-limit workaround applies.
# The `?query=` deep-link param is real and supported by Temporal UI
# 2.53.3 (verified live), unlike the still-inert `?host=` param on the
# omnigent tile above.
resource "coder_app" "temporal" {
  count        = data.coder_parameter.temporal_owned.value ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "temporal"
  display_name = "Temporal Workflows"
  external     = true
  icon         = "${var.temporal_ui_public_url}/favicon.ico"
  url          = "${var.temporal_ui_public_url}/namespaces/default/workflows?query=WorkflowId%20STARTS_WITH%20%22${data.coder_workspace.me.name}%22"
}

# Issue #60: JupyterLab, run as an in-workspace process (not a platform
# compose service) and proxied through Coder's own authenticated agent
# proxy — see coder/Dockerfile's "JupyterLab" layer and this template's
# README for the full design rationale. No token/password: the ONLY way to
# reach this listener is through Coder's session-authenticated proxy, since
# it binds 127.0.0.1 inside the workspace container only.
#
# `count` makes this a true no-op (zero resources) when enable_jupyter
# stays false (the default) — no process, no tile, no behaviour change.
#
# History (condensed — see #60/#62/#76/#81/#83 for full evidence): Coder's
# real path-based coder_app proxy strips the `/@owner/ws.../apps/<slug>`
# prefix with no `X-Forwarded-Prefix` header, so neither `--ServerApp.
# base_url` (#81) nor mounting at root with a rewriting shim (#62, the
# `jupyter-proxy-shim.py` this superseded) could ever be a complete fix
# while `coder_app.jupyter` stayed path-based — the shim covered HTML/JS/
# CSS rewriting but was extra maintained surface for a proxy-mode problem.
# Issue #83 then switched to `subdomain = true` (+ `CODER_WILDCARD_ACCESS_URL`)
# to sidestep prefix-stripping entirely — it worked, but requires every
# client's DNS resolver to reach the public internet to resolve the
# `*.<ip>.nip.io` wildcard hostname, a hard blocker in locked-down
# enterprise/private networks with no external DNS path. SUPERSEDED by
# Issue #94 below.
#
# Issue #94 fixes this properly, with zero DNS dependency: since this
# workspace's own fixed prefix (`/@<owner>/<workspace>/apps/jupyter`) is
# known at Terraform-plan time, a tiny local Caddy reverse-proxy sidecar
# (127.0.0.1:8888) unconditionally re-adds that same fixed prefix to every
# bare/stripped incoming request before forwarding to jupyter_server
# (127.0.0.1:8889, launched with a matching `--ServerApp.base_url`) — this
# reconstructs exactly the invariant JupyterHub's own `configurable-http-
# proxy` relies on (prefix-preserving proxy + matching `base_url`), just
# enforced locally instead of by Coder's proxy. `coder_app.jupyter` now
# points at Caddy (8888), not jupyter_server (8889) directly, and is back
# to `subdomain = false` (plain path-based routing, identical to Node-RED).
# Live-validated prototype: real jupyter-lab + real Caddy, main page,
# static assets, API, and the WebSocket kernel channel (real 101 upgrade +
# streamed kernel status messages) all confirmed working. Same
# `--ServerApp.allow_remote_access=True` flag is still required (Tornado's
# DNS-rebinding Host-header check — unrelated to Coder's proxy, safe here
# since the only network path to jupyter_server is still this local Caddy
# sidecar, which is itself only reachable via Coder's own authenticated
# proxy on 127.0.0.1:8888).
resource "coder_script" "jupyter" {
  count              = data.coder_parameter.enable_jupyter.value ? 1 : 0
  agent_id           = coder_agent.main.id
  display_name       = "JupyterLab"
  icon               = "/icon/jupyter.svg"
  run_on_start       = true
  start_blocks_login = false
  script             = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    # PID-file guard, NOT `pgrep -f` — a `pgrep -f` inside a script that is
    # itself run as `sh -c "<script text>"` can self-match its own command
    # line (AGENTS.md Issue #45 lesson).
    JUPYTER_PREFIX="/@${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}/apps/jupyter"

    JUPYTER_PIDFILE=/tmp/jupyter.pid
    if ! { [ -f "$JUPYTER_PIDFILE" ] && kill -0 "$(cat "$JUPYTER_PIDFILE")" 2>/dev/null; }; then
      nohup /usr/local/bin/jupyter-lab \
        --ServerApp.ip=127.0.0.1 \
        --ServerApp.port=8889 \
        --ServerApp.base_url="$JUPYTER_PREFIX" \
        --IdentityProvider.token='' \
        --ServerApp.password='' \
        --ServerApp.root_dir="${local.workspace_dir}" \
        --ServerApp.allow_remote_access=True \
        --no-browser \
        > /tmp/jupyter.log 2>&1 &
      echo $! > "$JUPYTER_PIDFILE"
    fi

    CADDY_PIDFILE=/tmp/jupyter-caddy.pid
    if ! { [ -f "$CADDY_PIDFILE" ] && kill -0 "$(cat "$CADDY_PIDFILE")" 2>/dev/null; }; then
      cat > /tmp/jupyter-caddy.Caddyfile <<-CADDYFILE
        :8888 {
        	# Coder's real proxy has already stripped the
        	# "/@owner/ws/apps/slug" prefix from the incoming request before it
        	# reaches us -- so we receive BARE paths. We must add the prefix
        	# back before forwarding to jupyter_server, which was launched with
        	# a matching --ServerApp.base_url and therefore only understands
        	# prefixed paths.
        	rewrite * $JUPYTER_PREFIX{uri}

        	reverse_proxy 127.0.0.1:8889
        }
        CADDYFILE
      nohup /usr/local/bin/caddy run --config /tmp/jupyter-caddy.Caddyfile --adapter caddyfile \
        > /tmp/jupyter-caddy.log 2>&1 &
      echo $! > "$CADDY_PIDFILE"
    fi
  EOT
}

# Issue #60: Node-RED, same in-workspace-process shape as jupyter above,
# also mounted at root (no NODE_RED_BASE_PATH) — LIVE-VERIFIED to work
# end-to-end through the real Coder dashboard proxy (editor SPA loads,
# assets load, /flows and /nodes both respond correctly), unlike Jupyter:
# Node-RED's own HTML emits RELATIVE asset paths ("vendor/vendor.js", not
# "/vendor/vendor.js"), so they resolve correctly relative to whatever
# prefixed URL the browser is actually on, even though Coder's proxy
# strips that same prefix before forwarding the request itself (see
# coder_script.jupyter's comment above for the full finding). No
# CODER_WORKSPACE_OWNER_NAME/CODER_WORKSPACE_NAME resolution is needed
# here at all as a result — simpler than the issue's original plan.
resource "coder_script" "nodered" {
  count              = data.coder_parameter.enable_nodered.value ? 1 : 0
  agent_id           = coder_agent.main.id
  display_name       = "Node-RED"
  run_on_start       = true
  start_blocks_login = false
  script             = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    PIDFILE=/tmp/node-red.pid
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      exit 0
    fi
    mkdir -p /home/coder/.node-red
    export NODE_RED_USER_DIR=/home/coder/.node-red
    export NODE_RED_PORT=1880
    nohup node-red --settings /opt/node-red/settings.js \
      > /tmp/node-red.log 2>&1 &
    echo $! > "$PIDFILE"
  EOT
}

# Issue #60: JupyterLab tile. Same-origin icon (bundled with Coder, verified
# live 200 at /icon/jupyter.svg) — NO CODER_ADDITIONAL_CSP_POLICY change
# needed, unlike Issue #47/#50's plain-http-origin tiles.
#
# Issue #94: back to path-based routing (subdomain = false), via the Caddy
# fixed-prefix sidecar started by coder_script.jupyter above — supersedes
# #83's subdomain-routed approach (no CODER_WILDCARD_ACCESS_URL dependency
# anymore). See coder_script.jupyter's comment for the full history.
resource "coder_app" "jupyter" {
  count        = data.coder_parameter.enable_jupyter.value ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "jupyter"
  display_name = "JupyterLab"
  icon         = "/icon/jupyter.svg"
  # Points at the Caddy sidecar (8888), not jupyter_server (8889) directly
  # — see coder_script.jupyter's comment above (Issue #94).
  url       = "http://localhost:8888"
  subdomain = false
  share     = "owner"
  order     = 2
  healthcheck {
    # Bare path — Caddy re-adds the fixed prefix before forwarding to
    # jupyter_server, same as every other request through this sidecar.
    url       = "http://localhost:8888/api"
    interval  = 5
    threshold = 10
  }
}

# Issue #60: Node-RED tile. `/icon/node.svg` is bundled with Coder
# (same-origin, no CSP impact) — Node-RED has no bundled icon of its own
# (`/icon/node-red.svg`/`/icon/nodered.svg` both 404 live). Overridable via
# var.nodered_icon for anyone who accepts an external-origin icon instead.
resource "coder_app" "nodered" {
  count        = data.coder_parameter.enable_nodered.value ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "nodered"
  display_name = "Node-RED"
  icon         = var.nodered_icon
  url          = "http://localhost:1880"
  subdomain    = false
  share        = "owner"
  order        = 3
  # Node-RED is mounted at root (see coder_script.nodered's comment above).
  healthcheck {
    url       = "http://localhost:1880/"
    interval  = 5
    threshold = 10
  }
}

# Issue #75: Tier-2 opt-in dashboard tile linking out to the omnigent chat
# UI, ported from agent-workspace/main.tf's coder_app.omnigent (Issue
# #43/#47/#45). `external = true` is the correct mechanism here (same
# rationale as that file's comment: no iframe/embedded-UI mechanism exists
# for coder_app in this Coder version, and omnigent-server is a separate,
# already-running container, not a process the workspace agent itself
# starts/reaches).
resource "coder_app" "omnigent" {
  count        = data.coder_parameter.enable_omnigent.value ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "omnigent"
  display_name = "Omnigent Chat"
  # Issue #47: `workspace_apps.icon` is varchar(256) in Coder's Postgres
  # schema — the real Omnigent favicon SVG/PNG cannot be embedded as a
  # `data:` URI at any reasonable resolution (verified live, see
  # agent-workspace/main.tf's identical comment). Using omnigent_public_url
  # directly introduces no *new* runtime dependency: this coder_app is
  # `external = true`, so the browser must already reach omnigent_public_url
  # directly to use the app at all; the icon fetch shares that exact same,
  # already-required reachability.
  icon     = "${var.omnigent_public_url}/favicon.svg"
  external = true
  # Uses omnigent_public_url (browser-reachable loopback), NOT
  # omnigent_server_url (internal compose DNS name used by the startup
  # script's own login/registration calls) — see variables.tf.
  #
  # The `?host=` query param is currently INERT: omnigent's shipped web UI
  # ignores unrecognized query params and always lands on New Chat — kept
  # only as forward-compatible plumbing pending upstream deep-link support
  # (omnigent-ai/omnigent#5881). Do not "fix" this locally.
  url = "${var.omnigent_public_url}/?host=${local.omnigent_host_name}"
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"

  # Protect the volume from being deleted due to changes in attributes.
  # This is the same persistent volume M4 uses for Agent Host state
  # (~/.vscode, ~/.vscode-server) alongside the cloned repository.
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

  # Issue #75: attach to the `platform-workspaces` Docker network
  # (defined in the repo-root compose.yaml) so the workspace container can
  # resolve/reach `omnigent-server` by its compose service name when
  # `enable_omnigent=true` — same network agent-workspace already attaches
  # to for the same reason (Issue #13 Task 8b, `lab-sim`). Attached
  # unconditionally (not gated behind `enable_omnigent`, which cannot be
  # used to conditionally toggle a single resource's `networks_advanced`
  # block) — this only adds network *reachability*, no new process/login/
  # container dependency for the `enable_omnigent=false` default case.
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
