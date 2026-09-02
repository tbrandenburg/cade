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
  description = "Icon for the Node-RED tile (Issue #60). Defaults to the real Node-RED brand icon via Simple Icons (CC0, https://cdn.simpleicons.org/nodered, verified live 200 image/svg+xml) — needs CODER_ADDITIONAL_CSP_POLICY's img-src widened for that origin (already done in compose.yaml). Restored as the default in Issue #90 after Issue #73 mistakenly reconciled an unintended live-server regression (drift back to the generic icon) as if it were a deliberate decision. Set to \"/icon/node.svg\" (Coder-bundled generic Node.js icon, same-origin, no CSP impact) instead if outbound Internet from the browser to the Simple Icons CDN is genuinely not acceptable for a given deployment."
  type        = string
  default     = "https://cdn.simpleicons.org/nodered"
}

# Issue #75: ported verbatim (comment + value) from
# coder/templates/agent-workspace/variables.tf — see that file's comment
# for the full rationale (no Terraform<->OpenBao data-source pattern exists
# yet; real credential lives in OpenBao at
# secret/devenv-cloud/omnigent/host-account). Only used when
# `enable_omnigent` (main.tf) is true.
variable "omnigent_server_url" {
  default     = "http://omnigent-server:8000"
  description = "Omnigent server URL, reachable from workspace containers via the `platform-workspaces` Docker network (compose service name). Not a secret. Only used when enable_omnigent=true."
  type        = string
}

# Issue #75: ported verbatim from agent-workspace/variables.tf — see that
# file's comment for why this is a SEPARATE variable from
# `omnigent_server_url` (internal compose DNS name vs. browser-reachable
# loopback URL, matching compose.yaml's `127.0.0.1:${OMNIGENT_PORT:-8000}`
# publish default).
variable "omnigent_public_url" {
  default     = "http://localhost:8000"
  description = "Public-facing (browser-reachable) Omnigent URL, used only for the dashboard tile link. Distinct from `omnigent_server_url` (internal compose DNS name, used only by the startup script's own login/registration calls). Not a secret. Only used when enable_omnigent=true."
  type        = string
}

# Issue #75: ported verbatim from agent-workspace/variables.tf. "plain"
# spawns bare `opencode` (verification-only) and must NEVER be the default
# in a pushed template version.
variable "omnigent_sandbox_mode" {
  default     = "srt"
  description = "How the omnigent-spawned opencode harness resolves its `opencode` binary: \"srt\" (default, sandboxed via `srt opencode --`) or \"plain\" (bare `opencode`, verification-only, never the shipped default). Only used when enable_omnigent=true."
  type        = string
  validation {
    condition     = contains(["srt", "plain"], var.omnigent_sandbox_mode)
    error_message = "omnigent_sandbox_mode must be either \"srt\" or \"plain\"."
  }
}
