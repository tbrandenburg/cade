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
  description = "Pre-built outer/bootstrap workspace image tag (contains the Docker engine, Node.js, and @devcontainers/cli — not the project toolchain). Build it first with `make devcontainer-workspace-build` (optionally CACERT=<path> behind a MITM proxy). The *inner* container's toolchain instead comes from the cloned repo's own `.devcontainer/devcontainer.json`, built at workspace-start time by the devcontainer CLI against a nested (Docker-in-Docker), per-workspace daemon."
  type        = string
}
