variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

variable "repo_url" {
  default     = ""
  description = "Repository to auto-clone into the workspace on first start. Leave empty for a blank workspace (bring your own project). To dogfood cade itself, pass --parameter repo_url=https://github.com/tbrandenburg/cade.git at `coder create` time."
  type        = string
}

variable "bootstrap_image" {
  default     = "cade/devcontainer-bootstrap:latest"
  description = "Pre-built outer/bootstrap workspace image tag (contains the Docker engine, Node.js, and @devcontainers/cli — not the project toolchain). Build it first with `make devcontainer-workspace-build` (optionally CACERT=<path> behind a MITM proxy). The *inner* container's toolchain instead comes from the cloned repo's own `.devcontainer/devcontainer.json`, built at workspace-start time by the devcontainer CLI against a nested (Docker-in-Docker), per-workspace daemon."
  type        = string
}

variable "default_devcontainer_image" {
  default     = "mcr.microsoft.com/devcontainers/base:ubuntu"
  description = "Public devcontainer base image used to bootstrap a minimal .devcontainer/devcontainer.json when repo_url is empty and the cloned repo (or blank workspace) has no devcontainer config of its own."
  type        = string
}
