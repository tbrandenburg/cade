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
}

provider "docker" {
  host = var.docker_socket != "" ? var.docker_socket : null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

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
  EOT

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
    GITHUB_TOKEN        = data.coder_parameter.github_token.value
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
# render for every docker-standard workspace, only ones Temporal itself
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
# IMPORTANT, corrected from the issue's own original plan after LIVE
# verification against the real running Coder server (v2.36.3): Jupyter is
# run WITHOUT --ServerApp.base_url (i.e. mounted at "/", not at a
# workspace-specific `/@owner/ws.../apps/jupyter` prefix). A raw Python
# echo-server test proved Coder's real path-based coder_app proxy STRIPS
# the `/@owner/ws.../apps/<slug>` prefix and forwards only the bare
# remainder path to the app's `url` — it does NOT preserve/forward the
# full original path, and sends no `X-Forwarded-Prefix` header either.
# Setting base_url to the full prefix (the issue's original plan, and the
# conventional JupyterHub-style reverse-proxy pattern) therefore made
# EVERY request 404 through the real dashboard proxy (confirmed live),
# even though it looks correct when curled directly against the container
# (which is why this bug is easy to miss — always verify through the
# REAL proxy, not just a direct container curl, per this repo's own
# anti-deception rules). Mounting at root instead fixes the main page and
# API routes; JupyterLab's OWN static-asset markup still uses
# domain-absolute paths ("/static/lab/..."), which is a KNOWN, LIVE-VERIFIED,
# NOT-FIXED-HERE follow-up limitation — see
# docs/milestone-reports/issue-60-jupyter-nodered.md and the "Follow-up
# issues found" section of this issue's handoff for the full writeup and
# workaround (`coder port-forward`).
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
    PIDFILE=/tmp/jupyter.pid
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      exit 0
    fi
    nohup /usr/local/bin/jupyter-lab \
      --ServerApp.ip=127.0.0.1 \
      --ServerApp.port=8888 \
      --IdentityProvider.token='' \
      --ServerApp.password='' \
      --ServerApp.root_dir="${local.workspace_dir}" \
      --no-browser \
      > /tmp/jupyter.log 2>&1 &
    echo $! > "$PIDFILE"
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
resource "coder_app" "jupyter" {
  count        = data.coder_parameter.enable_jupyter.value ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "jupyter"
  display_name = "JupyterLab"
  icon         = "/icon/jupyter.svg"
  url          = "http://localhost:8888"
  subdomain    = false
  share        = "owner"
  order        = 2
  # Now that Jupyter is mounted at root (see coder_script.jupyter's
  # comment above — Coder's real path-based proxy strips the URL prefix
  # rather than preserving it), a bare "/api" is correct.
  healthcheck {
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
