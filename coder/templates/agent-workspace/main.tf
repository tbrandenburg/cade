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

# This template exists specifically for long-running Coder Agent sessions,
# so `agent_capable` defaults to true here (unlike `docker-standard`, where
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
  EOT

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
    GITHUB_TOKEN        = data.coder_parameter.github_token.value
    LAB_SIM_AGENT_TOKEN = data.coder_parameter.lab_sim_agent_token.value
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
  # `docker-standard` nor `embedded-linux` templates currently attach to
  # this network (verified: no `networks_advanced` block in either), so
  # this is a new addition here, not an inherited/duplicated one.
  networks_advanced {
    name = "platform-workspaces"
  }

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
