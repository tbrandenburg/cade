variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

variable "repo_url" {
  default     = "https://github.com/tbrandenburg/cade.git"
  description = "Repository to auto-clone into every docker-workspace workspace"
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
  description = "Icon for the Node-RED tile (Issue #60). Defaults to the real Node-RED brand icon via Simple Icons (CC0, https://cdn.simpleicons.org/nodered, verified live 200 image/svg+xml) — needs CODER_ADDITIONAL_CSP_POLICY's img-src widened for that origin (already done in compose.yaml). Set to \"/icon/node.svg\" (Coder-bundled generic Node.js icon, same-origin, no CSP impact) if outbound Internet from the browser is not acceptable."
  type        = string
  default     = "https://cdn.simpleicons.org/nodered"
}
