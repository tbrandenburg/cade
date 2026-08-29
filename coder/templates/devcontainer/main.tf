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

  # `devcontainer_path` is "path (relative to the cloned repo root)
  # containing devcontainer.json" (e.g. `.devcontainer` or
  # `examples/hello-service/.devcontainer`), but `coder_devcontainer`'s
  # `workspace_folder` expects the *parent* folder that directly contains a
  # `.devcontainer/` subdirectory (matches Coder's own reference template:
  # https://github.com/coder/coder/blob/v2.36.3/examples/templates/docker-devcontainer/main.tf,
  # where `workspace_folder = "~/${module.git-clone[0].folder_name}"` is the
  # repo root itself, one level above its `.devcontainer/`).
  devcontainer_parent_dir = dirname(data.coder_parameter.devcontainer_path.value)
  workspace_folder        = local.devcontainer_parent_dir == "." ? local.workspace_dir : "${local.workspace_dir}/${local.devcontainer_parent_dir}"
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

  # No manual git-clone/devcontainer-cli invocation here anymore -- both are
  # handled by the `git-clone` module and the native `coder_devcontainer`
  # resource below. This script only starts the nested (per-workspace)
  # Docker-in-Docker daemon that `coder_devcontainer` needs to build/run the
  # inner container against, and applies the agent_capable autostop toggle.
  startup_script = <<-EOT
    set -e

    sudo service docker start

    # Wait for the nested daemon to actually accept connections before the
    # git-clone/devcontainer coder_script(s) (which run concurrently, not
    # necessarily after this one) try to use it.
    for i in $(seq 1 30); do
      if docker info >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    if [ "${data.coder_parameter.agent_capable.value}" = "true" ] && command -v coder >/dev/null 2>&1; then
      coder schedule stop "$(hostname)" --disable-ttl || true
    fi
  EOT

  # Runs the shutdown-time docker cleanup only if the daemon is actually up
  # (avoids a noisy failure on a workspace that never finished starting).
  shutdown_script = <<-EOT
    set -e
    if docker info >/dev/null 2>&1; then
      docker system prune -a -f || true
    fi
    sudo service docker stop || true
  EOT

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
    # GIT_ASKPASS points at a script baked into the bootstrap image
    # (coder/devcontainer/Dockerfile) that just echoes GITHUB_TOKEN -- the
    # `git-clone` registry module (registry.coder.com/coder/git-clone) has
    # no token/auth input of its own, it only runs `git clone`, so
    # credential injection has to happen via the ambient git environment
    # instead, same as the previous inline-script approach.
    GITHUB_TOKEN        = data.coder_parameter.github_token.value
    GIT_ASKPASS         = "/usr/local/bin/git-askpass.sh"
    GIT_TERMINAL_PROMPT = "0"
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

# See https://registry.coder.com/modules/coder/git-clone
module "git-clone" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "~> 2.0"
  agent_id = coder_agent.main.id
  url      = local.repo_url
  base_dir = "/home/coder"
  folder_name = "project"
}

# @devcontainers/cli is baked into coder/devcontainer/Dockerfile (npm
# install -g) rather than installed via the
# registry.coder.com/coder/devcontainers-cli module: this repo already has a
# working, pinned bootstrap-image install path for it, and swapping it for
# the module would add a network-dependent `coder_script` npm install to
# every workspace start for no behavioral gain.

# Automatically start the devcontainer for the workspace via Coder's native
# resource, replacing the previous manual `devcontainer up`/`devcontainer
# exec` shell invocations against a bind-mounted host socket.
resource "coder_devcontainer" "repo" {
  count            = data.coder_workspace.me.start_count
  agent_id         = coder_agent.main.id
  workspace_folder = local.workspace_folder
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

# Persists the nested Docker-in-Docker daemon's own data dir across
# workspace restarts, so the devcontainer image/layer cache survives (same
# fixed-name + ignore_changes pattern as home_volume above).
resource "docker_volume" "docker_volume" {
  name = "coder-${data.coder_workspace.me.id}-docker"

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

  # Nested (per-workspace) Docker-in-Docker daemon instead of
  # docker-outside-of-docker: a live E2E found bind-mounting the host's
  # `/var/run/docker.sock` fundamentally broken for this template (the
  # shared host daemon resolves bind-mount source paths against the real
  # host filesystem, not this container's named-volume-backed one -- see
  # docs/devcontainer-security-notes.md). Coder's own reference template
  # (examples/templates/docker-devcontainer, coder/coder v2.36.3) uses
  # `privileged = true` + a dedicated `/var/lib/docker` volume instead, and
  # explicitly documents host-socket mounting as "strongly discouraged"
  # because workspaces then compete for control of the devcontainers.
  privileged = true

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  volumes {
    container_path = "/var/lib/docker"
    volume_name    = docker_volume.docker_volume.name
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
