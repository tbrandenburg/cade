variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

variable "repo_url" {
  default     = "https://github.com/tbrandenburg/cade.git"
  description = "Repository to auto-clone into every agent-workspace workspace"
  type        = string
}

variable "workspace_image" {
  default     = "cade/agent-workspace:latest"
  description = "Pre-built workspace image tag. Build it first with `make agent-workspace-build` (optionally CACERT=<path> behind a MITM proxy) — Coder templates only upload this directory, not the repository root, so the image cannot be built inline from ../../Dockerfile."
  type        = string
}

# Issue #43 Step 5 (corrected): omnigent host registration. The real
# credential (shared first-admin account for now) lives in OpenBao at
# `secret/devenv-cloud/omnigent/host-account` as `url`/`username`/
# `password` (a real accounts-mode login pair, not a bearer token — the
# omnigent CLI has no such flag) — this template does NOT read it
# directly. No Terraform<->OpenBao data-source pattern exists anywhere
# else in this repo's templates yet (verified: no `vault`/`bao`/
# `openbao` reference in any other `main.tf`), and building real per-workspace
# OpenBao-backed secret injection (e.g. via an AppRole token minted per
# workspace) is a non-trivial follow-up, not something to solve inline here.
# The simplest robust option consistent with "keep changes minimal": expose
# the server URL as a plain (non-secret) variable, and the username/password
# as optional `coder_parameter`s (see main.tf) — same optional/default-empty
# pattern already used for `github_token`/`lab_sim_agent_token` above.
variable "omnigent_server_url" {
  default     = "http://omnigent-server:8000"
  description = "Omnigent server URL, reachable from workspace containers via the `platform-workspaces` Docker network (compose service name). Not a secret."
  type        = string
}

# Issue #43 Step 6: deliberately a SEPARATE variable from
# `omnigent_server_url` above, not a reuse of it. `omnigent_server_url` is
# the internal compose DNS name (`omnigent-server:8000`), resolvable only
# from other containers on the `platform-workspaces` network — it is what
# the startup script uses for its own login/registration calls, and it is
# NOT reachable from a human operator's own browser. This variable is the
# public-facing loopback URL a browser can actually open, matching
# compose.yaml's `127.0.0.1:${OMNIGENT_PORT:-8000}` publish default and
# .env.example's `OMNIGENT_ACCOUNTS_BASE_URL` default — used only by the
# `coder_app.omnigent` dashboard tile in main.tf.
variable "omnigent_public_url" {
  default     = "http://localhost:8000"
  description = "Public-facing (browser-reachable) Omnigent URL, used only for the dashboard tile link. Distinct from `omnigent_server_url` (internal compose DNS name, used only by the startup script's own login/registration calls) — matches compose.yaml's published port default. Not a secret."
  type        = string
}

# "plain" spawns bare `opencode` (verification-only: proves the omnigent
# harness itself works, without srt's sandboxing) and must NEVER be the
# default in a pushed template version. "srt" (the default) routes the
# omnigent-spawned harness through the same `srt opencode --` wrapping
# already used for the interactive `opencode` alias in main.tf, so there is
# only one (sandboxed) code path for actually running agent turns.
variable "omnigent_sandbox_mode" {
  default     = "srt"
  description = "How the omnigent-spawned opencode harness resolves its `opencode` binary: \"srt\" (default, sandboxed via `srt opencode --`) or \"plain\" (bare `opencode`, verification-only, never the shipped default)."
  type        = string
  validation {
    condition     = contains(["srt", "plain"], var.omnigent_sandbox_mode)
    error_message = "omnigent_sandbox_mode must be either \"srt\" or \"plain\"."
  }
}
