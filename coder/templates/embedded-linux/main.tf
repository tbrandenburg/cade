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

# Milestone M7: sccache compiler cache. Deliberately *not* a
# `docker_volume` resource owned by this workspace's Terraform state —
# `coder delete` destroys every resource in that state, which would take
# this volume down with it even with `ignore_changes = all` (that only
# ignores attribute *changes* on apply, not destroy). Referencing a fixed
# volume name in `docker_container.volumes` below is enough: Docker
# auto-creates it on first use (like `docker run -v name:path`) and it is
# never a member of any single workspace's state, so it survives
# `coder delete`/`coder create` across every workspace from this template.
# See cache/sccache/README.md.
locals {
  sccache_volume_name = "cade-sccache-cache"
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

  # Milestone M7: mounted *inside* the per-workspace home volume's mount
  # point above — a separate, shared volume nested at a subdirectory is a
  # normal second bind mount in the container's mount namespace.
  volumes {
    container_path = "/home/coder/.cache/sccache"
    volume_name    = local.sccache_volume_name
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
