# `docker-standard` Coder template (Milestone M3)

Provisions the first `docker-standard` workspace type: a Docker container built
from `coder/Dockerfile`, with the repository auto-cloned into
`/home/coder/project` and a persistent per-workspace home volume.

## Contents

- `main.tf` — the Coder/Terraform resources: `coder_agent`, code-server
  module, `docker_volume` (persistent `/home/coder`), and `docker_container`
  (uses the pre-built `workspace_image`).
- `variables.tf` — `docker_socket` (optional Docker socket override),
  `repo_url` (repository to clone; defaults to this repository), and
  `workspace_image` (pre-built image tag; see below).

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
coder templates push docker-standard \
  --directory coder/templates/docker-workspace \
  --var repo_url=https://github.com/<org>/cade.git
```

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

## Optional workspace apps: JupyterLab and Node-RED (Issue #60)

Two independent, opt-in dashboard tiles, both `false` by default (zero
behaviour change for existing workspaces):

- `enable_jupyter` (`coder_parameter`) — starts JupyterLab
  (`coder_script.jupyter`) and shows a "JupyterLab" tile
  (`coder_app.jupyter`).
- `enable_nodered` (`coder_parameter`) — starts Node-RED
  (`coder_script.nodered`) and shows a "Node-RED" tile
  (`coder_app.nodered`).

Both run as plain processes inside the workspace container (not platform
`compose.yaml` services), bound to `127.0.0.1` only — the *only* way to
reach either is through Coder's own authenticated agent proxy, so neither
has its own login. See `docs/operations.md` and `docs/security.md` for the
full design/data-location/log-location writeup, and
`scripts/set-workspace-jupyter.sh` / `scripts/set-workspace-nodered.sh` to
retro-fit either tile onto an already-created workspace.

**Known limitation (live-verified, Issue #60)**: JupyterLab's own SPA emits
domain-absolute static asset paths (`/static/lab/...`), which do not
resolve correctly once the browser is at the tile's prefixed URL, because
Coder's own path-based `coder_app` proxy strips that prefix before
forwarding to the app. Node-RED is unaffected (its assets are
relative-path). Workaround: `coder port-forward <workspace> --tcp
8888:8888` and open `http://localhost:8888/lab` directly. See this
issue's milestone report for full evidence.
