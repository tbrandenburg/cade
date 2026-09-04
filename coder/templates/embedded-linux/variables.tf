variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

variable "workspace_image" {
  default     = "cade/embedded-linux-workspace:latest"
  description = "Pre-built embedded-linux workspace image tag (Milestone M6): the docker-workspace image plus a pinned aarch64 cross-compilation toolchain (cmake, ninja, gcc-aarch64-linux-gnu, qemu-user). Build it first with `make embedded-workspace-build` (optionally CACERT=<path> behind a MITM proxy) — Coder templates only upload this directory, not the repository root, so the image cannot be built inline from ../../embedded-linux/Dockerfile."
  type        = string
}
