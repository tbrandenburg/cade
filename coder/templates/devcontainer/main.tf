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
# Same pattern as the docker-standard template (coder/templates/docker-workspace/main.tf).
data "coder_parameter" "github_token" {
  name         = "github_token"
  display_name = "GitHub Token"
  description  = "Optional token to clone `repo_url` when it is not publicly readable. Leave empty for public repos."
  type         = "string"
  default      = ""
  mutable      = true
  order        = 1
}

data "coder_parameter" "agent_capable" {
  name         = "agent_capable"
  display_name = "Agent-capable (disable aggressive autostop)"
  description  = "Set true for workspaces expected to run long Agent Host sessions unattended. Human-only workspaces should leave this false and keep the default autostop."
  type         = "bool"
  default      = "false"
  mutable      = true
  order        = 2
}

# Path (relative to the cloned repo root) of the devcontainer.json to build
# and run. Defaults to the spec's own default location. Every coder_parameter
# must be passed explicitly on `coder create --parameter` (see AGENTS.md) --
# omitting one hangs the build with an opaque `prepare build: EOF`.
data "coder_parameter" "devcontainer_path" {
  name         = "devcontainer_path"
  display_name = "Devcontainer path"
  description  = "Path (relative to the cloned repo root) containing devcontainer.json, e.g. `.devcontainer` or `examples/hello-service/.devcontainer`."
  type         = "string"
  default      = ".devcontainer"
  mutable      = true
  order        = 3
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # Clone the repository (idempotent, verbatim from the docker-standard
  # template's GIT_ASKPASS pattern), then build/run the repo's own
  # .devcontainer/devcontainer.json via the devcontainer CLI instead of
  # assuming a fixed toolchain.
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

    DEVCONTAINER_JSON="${local.workspace_dir}/${data.coder_parameter.devcontainer_path.value}/devcontainer.json"

    # Fail fast with a specific message instead of a generic connection/EOF
    # error -- this is the first of the two required MVP guardrails (no
    # devcontainer.json / dockerComposeFile devcontainers are out of scope).
    if [ ! -f "$DEVCONTAINER_JSON" ]; then
      echo "ERROR: no devcontainer.json found at $DEVCONTAINER_JSON" | tee -a /tmp/coder-startup-script.log
    elif grep -q "dockerComposeFile" "$DEVCONTAINER_JSON"; then
      echo "ERROR: unsupported: dockerComposeFile ($DEVCONTAINER_JSON) -- this template only supports image:/build.dockerfile: devcontainers" | tee -a /tmp/coder-startup-script.log
    else
      devcontainer up \
        --workspace-folder "${local.workspace_dir}" \
        --config "$DEVCONTAINER_JSON" \
        --id-label "coder.workspace_id=${data.coder_workspace.me.id}" \
        2>&1 | tee -a /tmp/coder-startup-script.log
    fi

    # Convenience alias so a developer/agent inside the outer container can
    # run commands inside the devcontainer-built inner container without
    # retyping --workspace-folder/--config every time.
    if ! grep -q "alias devcontainer-exec=" ~/.bashrc 2>/dev/null; then
      cat >> ~/.bashrc <<BASHRC_ALIASES
alias devcontainer-exec='devcontainer exec --workspace-folder "${local.workspace_dir}" --config "$DEVCONTAINER_JSON"'
BASHRC_ALIASES
    fi

    if [ ! -f "${local.workspace_dir}/.vscode/settings.json" ]; then
      mkdir -p "${local.workspace_dir}/.vscode"
      cat > "${local.workspace_dir}/.vscode/settings.json" <<'VSCODE_SETTINGS'
{}
VSCODE_SETTINGS
    fi

    if [ "${data.coder_parameter.agent_capable.value}" = "true" ] && command -v coder >/dev/null 2>&1; then
      coder schedule stop "$(hostname)" --disable-ttl || true
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

  # Same fixed-name + ignore_changes pattern as docker-workspace, so
  # Durability Test 3 holds for this template too (AGENTS.md: ignore_changes
  # does not protect the volume from `coder delete`, only from `apply` diffs).
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
  image = var.bootstrap_image
  name  = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"

  hostname   = data.coder_workspace.me.name
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  # docker-outside-of-docker: the outer container needs the host's Docker
  # socket so `devcontainer up` can create the inner container next to it.
  volumes {
    container_path = "/var/run/docker.sock"
    host_path      = "/var/run/docker.sock"
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
