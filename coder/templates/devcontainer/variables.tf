variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

variable "repo_url" {
  default     = "https://github.com/tbrandenburg/cade.git"
  description = "Repository to auto-clone into every devcontainer workspace"
  type        = string
}

variable "bootstrap_image" {
  default     = "cade/devcontainer-bootstrap:latest"
  description = "Pre-built outer/bootstrap workspace image tag (contains the Docker CLI, Node.js, and @devcontainers/cli only — not the project toolchain). Build it first with `make devcontainer-workspace-build` (optionally CACERT=<path> behind a MITM proxy). The *inner* container's toolchain instead comes from the cloned repo's own `.devcontainer/devcontainer.json`, built at workspace-start time by the devcontainer CLI."
  type        = string
}

variable "docker_gid" {
  default     = "988"
  description = "GID of the host's `docker` group (find with `getent group docker`), so the outer bootstrap container's non-root `coder` user can access the bind-mounted `/var/run/docker.sock` for docker-outside-of-docker (`devcontainer up`/`devcontainer exec`). Leave empty to skip (only useful if the workspace runs as root)."
  type        = string
}
