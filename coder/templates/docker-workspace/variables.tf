variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

variable "repo_url" {
  default     = "https://github.com/tbrandenburg/devenv-cloud.git"
  description = "Repository to auto-clone into every docker-standard workspace"
  type        = string
}

variable "workspace_image" {
  default     = "devenv-cloud/coder-workspace:latest"
  description = "Pre-built workspace image tag. Build it first with `make coder-workspace-build` (optionally CACERT=<path> behind a MITM proxy) — Coder templates only upload this directory, not the repository root, so the image cannot be built inline from ../../Dockerfile."
  type        = string
}
