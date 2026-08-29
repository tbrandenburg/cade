# `devcontainer` Coder template (Issue #6, MVP)

Additive third template alongside `docker-standard`/`embedded-linux`: instead
of referencing a fixed pre-built workspace image, it clones the target repo
and builds/runs the workspace from **that repo's own**
`.devcontainer/devcontainer.json` via `@devcontainers/cli`.

## Contents

- `main.tf` — same `coder_agent`/code-server/`docker_volume`/`docker_container`
  shape as `coder/templates/docker-workspace/main.tf`, plus: a
  `devcontainer_path` parameter, a docker-outside-of-docker socket mount, and
  a startup script that runs `devcontainer up` against the cloned repo instead
  of assuming a fixed toolchain.
- `variables.tf` — `docker_socket`, `repo_url` (same as docker-standard), and
  `bootstrap_image` (the *outer* container's image — contains only the Docker
  CLI, Node.js, and `@devcontainers/cli`, not the project toolchain).

## Build the bootstrap image first

```bash
make devcontainer-workspace-build   # tags cade/devcontainer-bootstrap:latest
```

## Parameters (must ALL be passed explicitly on `coder create --parameter`)

| Parameter | Default | Notes |
|---|---|---|
| `github_token` | `""` | Optional, for private `repo_url` clones. |
| `agent_capable` | `false` | Same autostop-relaxation semantics as docker-standard. |
| `devcontainer_path` | `.devcontainer` | Path (relative to the cloned repo root) containing `devcontainer.json`. |

Example:

```bash
coder templates push devcontainer -d coder/templates/devcontainer --yes
coder create <owner>/<name> --template devcontainer --yes \
  --parameter github_token= --parameter agent_capable=false \
  --parameter devcontainer_path=examples/hello-service/.devcontainer
```

## MVP scope / known limitations

- Only `image:` and `build.dockerfile:` devcontainers are supported. A
  `devcontainer.json` using `dockerComposeFile` fails fast with an explicit
  "unsupported: dockerComposeFile" message in `/tmp/coder-startup-script.log`,
  not a silent partial workspace.
- A missing `devcontainer.json` at `devcontainer_path` fails fast with a
  specific "no devcontainer.json found at <path>" message in the same log.
- `docker_volume.home_volume` uses the same fixed-name + `ignore_changes`
  pattern as `docker-workspace`, so Durability Test 3 (AGENTS.md) applies here
  too — but `coder delete` still destroys it (see AGENTS.md Lessons Learned).
