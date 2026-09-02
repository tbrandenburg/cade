# `docker-workspace` Coder template (Milestone M3)

Provisions the first `docker-workspace` workspace type: a Docker container built
from `coder/Dockerfile`, with an optional repository auto-cloned into
`/home/coder/project` (or a blank project directory if none is given) and a
persistent per-workspace home volume.

## Contents

- `main.tf` — the Coder/Terraform resources: `coder_agent`, code-server
  module, `docker_volume` (persistent `/home/coder`), and `docker_container`
  (uses the pre-built `workspace_image`).
- `variables.tf` — `docker_socket` (optional Docker socket override),
  `repo_url` (repository to auto-clone; empty by default — bring your own
  project), and `workspace_image` (pre-built image tag; see below).

## Bring your own project (default) vs. dogfooding cade

By default `repo_url` is empty and `coder create` gives you a blank
`/home/coder/project` directory — cade is a generic devenv for *your*
project, not just for developing itself. To develop cade itself instead
(dogfooding/contributing), pass the override explicitly.

`repo_url` is a plain Terraform `variable`, not a `coder_parameter` — it
cannot be set via `coder create --parameter`; set it via `--var` at
`coder templates push` time (changes the default for every future
workspace created from this template) or a `TF_VAR_repo_url` environment
variable on the Coder provisioner:

```bash
coder templates push docker-workspace \
  --directory coder/templates/docker-workspace \
  --var repo_url=https://github.com/tbrandenburg/cade.git --yes
```

## Build the workspace image first

Coder only uploads this template directory to the provisioner, not the
repository root, so the workspace image cannot be built inline from
`../../Dockerfile`. Build and tag it on the Docker host Coder uses **before**
pushing or using this template:

```bash
make coder-workspace-build                       # unrestricted network
make coder-workspace-build CACERT=/path/to/ca.pem # behind a MITM proxy
```

This produces `cade/coder-workspace:latest`, the default value of
`workspace_image`.

## Push a template revision

```bash
coder templates push docker-workspace \
  --directory coder/templates/docker-workspace
```

`--var repo_url=...` on this push command would change the template
variable's server-side *default* for every future `coder create` from
this template (`repo_url` is a plain Terraform `variable`, not a
`coder_parameter` — it cannot be overridden per-workspace via `coder
create --parameter`) — leave it unset to keep the empty, bring-your-own-
project default; only set it here if you deliberately want a different
default for every workspace created from this template.

Per Coder's security best practices, push from CI using a dedicated
non-human account with the minimum required role — do not grant Template
Admin broadly, and never inline credentials in the `.tf` files (Coder
persists template versions indefinitely). Pass credentials via `TF_VAR_*`
environment variables or Coder parameters instead.

## Persistent home volume

`docker_volume.home_volume` is mounted at `/home/coder` and is the only
directory that survives a workspace container replace. It holds:

- `project/` — the cloned repository.
- Agent Host state added in M4 (`.vscode`, `.vscode-server`).
- Agent CLI credential/config directories added in M9 (`.copilot`, `.claude`).

## Corporate CA bundle

If the Coder host sits behind a MITM/TLS-intercepting proxy, build the
workspace image with the optional CA bundle (see `../Dockerfile` and the
repository root `Makefile`'s `coder-workspace-build` target):

```bash
make coder-workspace-build CACERT=/path/to/ca-bundle.pem
```

## Workspace app tiers

This template's dashboard apps (VS Code Web, SSH/Terminal, JupyterLab,
Node-RED, the Temporal Workflows link) all follow one consistent
three-tier convention. Any future opt-in app should follow the same
shape rather than inventing a new mechanism.

### Tier 1 — core, always on, no `coder_parameter`

- VS Code Web (`module.code-server` in `main.tf`) — gated only by
  `count = data.coder_workspace.me.start_count`, never by a
  `coder_parameter`.
- SSH / Web Terminal — Coder platform built-in via `coder_agent`, **not**
  a template-defined `coder_app` at all.

### Tier 2 — optional, creation-time `coder_parameter`

Each is a `bool` `coder_parameter`, default `"false"`, `mutable = true`,
gating the `count` on its `coder_app`/`coder_script` pair — pass
`--parameter <name>=true` at `coder create` time to opt in:

- `temporal_owned` → `coder_app.temporal` — a dashboard tile linking to
  the Temporal Workflows UI, filtered to this workspace.
- `enable_jupyter` → `coder_script.jupyter` + `coder_app.jupyter` —
  starts JupyterLab and shows a "JupyterLab" tile.
- `enable_nodered` → `coder_script.nodered` + `coder_app.nodered` —
  starts Node-RED and shows a "Node-RED" tile.
- `enable_omnigent` → a `startup_script` block (host daemon + reverse
  Unix-socket bridge) + `coder_app.omnigent` — starts the `omnigent host`
  daemon and shows an "Omnigent Chat" tile linking to the shared
  `omnigent-server` UI (Issue #75, ported from `agent-workspace`'s
  Issue #43/#45 integration). **Prerequisite**: `omnigent-db`/
  `omnigent-server` must already be up before this is useful —
  `docker compose up -d omnigent-db omnigent-server` then
  `make omnigent-bootstrap` (from the repository root) — otherwise the
  tile renders but the startup script's login/host-registration step
  fails (non-fatally logged, workspace boot is not blocked) and the tile
  will not reach a working chat session. Also pass
  `omnigent_admin_username`/`omnigent_admin_password` (the shared
  omnigent-server first-admin account, OpenBao
  `secret/devenv-cloud/omnigent/host-account`) at `coder create` time —
  leaving the password empty skips host registration entirely.

JupyterLab and Node-RED both run as plain processes inside the workspace
container (not platform `compose.yaml` services), bound to `127.0.0.1`
only — the *only* way to reach either is through Coder's own
authenticated agent proxy, so neither has its own login. See
`docs/operations.md` and `docs/security.md` for the full
design/data-location/log-location writeup.

**JupyterLab uses a fixed-prefix Caddy sidecar, no DNS required (Issue
#94)**: Coder's real path-based proxy strips the `/@owner/ws.../apps/<slug>`
prefix with no `X-Forwarded-Prefix` header, so plain path-based mode alone
can never work for an app (like JupyterLab) whose own static assets use
domain-absolute paths (see #60/#62/#76/#81/#83/#94 history in `main.tf`'s
comments). #83 previously worked around this with `subdomain = true` +
`CODER_WILDCARD_ACCESS_URL`, but that required every client's DNS resolver
to reach the public internet — a hard blocker on locked-down networks.
`coder_script.jupyter` now also starts a small in-workspace Caddy process
(127.0.0.1:8888) that re-adds the workspace's own fixed prefix to every
request before forwarding to `jupyter-lab` (127.0.0.1:8889, launched with
a matching `--ServerApp.base_url`); `coder_app.jupyter` points at Caddy
and is back to `subdomain = false`, identical to Node-RED's tile. No
`CODER_WILDCARD_ACCESS_URL`/DNS setup of any kind is required anymore.

### Tier 3 — optional, post-instantiation

Any Tier 2 parameter can be flipped on an *already-created* workspace, no
recreate needed, via the single generic entry point:

```bash
scripts/set-workspace-parameter.sh <owner>/<workspace> <param_name> <value>
```

`scripts/set-workspace-temporal-tile.sh`, `scripts/set-workspace-jupyter.sh`,
and `scripts/set-workspace-nodered.sh` are thin, byte-compatible wrapper
scripts around this one generic script — a new Tier 2 app gets Tier 3 for
free with no new script required. `enable_omnigent` works identically:
`scripts/set-workspace-omnigent.sh <owner>/<workspace> [true|false]` (a
thin wrapper, same pattern as the others) or the generic
`scripts/set-workspace-parameter.sh <owner>/<workspace> enable_omnigent true`
directly.
