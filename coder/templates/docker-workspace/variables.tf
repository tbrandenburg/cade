variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

variable "repo_url" {
  default     = "https://github.com/tbrandenburg/cade.git"
  description = "Repository to auto-clone into every docker-standard workspace"
  type        = string
}

variable "workspace_image" {
  default     = "cade/coder-workspace:latest"
  description = "Pre-built workspace image tag. Build it first with `make coder-workspace-build` (optionally CACERT=<path> behind a MITM proxy) — Coder templates only upload this directory, not the repository root, so the image cannot be built inline from ../../Dockerfile."
  type        = string
}

variable "temporal_ui_public_url" {
  description = "Browser-reachable Temporal UI URL (external=true coder_app, so the browser resolves it directly, not compose DNS)."
  type        = string
  default     = "http://localhost:8088"
}

variable "nodered_icon" {
  description = "Icon for the Node-RED tile (Issue #60). Defaults to a Coder-bundled, same-origin icon (no external dependency, no CSP impact). Set to \"https://cdn.simpleicons.org/nodered\" for the brand-accurate icon if outbound Internet from the browser is acceptable."
  type        = string
  default     = "/icon/node.svg"
}
