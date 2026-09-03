# `devcontainer` Coder template (Issue #6, MVP)

Additive third template alongside `docker-workspace`/`embedded-linux`: instead
of referencing a fixed pre-built workspace image, it clones the target repo
and builds/runs the workspace from **that repo's own**
`.devcontainer/devcontainer.json` via Coder's native `coder_devcontainer`
resource and `@devcontainers/cli`.

## Contents

- `main.tf` — same `coder_agent`/code-server/`docker_volume`/`docker_container`
  shape as `coder/templates/docker-workspace/main.tf`, plus: a
  `devcontainer_path` parameter, the `registry.coder.com/coder/git-clone`
  module, a native `coder_devcontainer` resource, and a **nested, per-workspace
  Docker-in-Docker daemon** (`privileged = true` + a dedicated
  `/var/lib/docker` volume) instead of bind-mounting the host's Docker
  socket. See "Why Docker-in-Docker, not docker-outside-of-docker" below.
- `variables.tf` — `docker_socket`, `repo_url` (repository to auto-clone;
  empty by default — bring your own project, same as docker-workspace),
  `default_devcontainer_image` (base image used to bootstrap a minimal
  `.devcontainer/devcontainer.json` when `repo_url` is empty — see "Bring
  your own project" below), and `bootstrap_image` (the *outer* container's
  image — contains the Docker engine, Node.js, and `@devcontainers/cli`,
  not the project toolchain).

## Bring your own project (default) vs. dogfooding cade

`repo_url` is a plain Terraform `variable`, not a `coder_parameter` — it
cannot be passed via `coder create --parameter`; set it via `--var` (at
`coder templates push` time, changing the default for every future
workspace) or a `TF_VAR_repo_url` environment variable on the Coder
provisioner. By default it is empty: `module.git-clone`'s own vendored
`coder_script` skips cloning gracefully, and this template's
`coder_script.empty_workspace_bootstrap` (gated on `repo_url == ""`)
writes a minimal `.devcontainer/devcontainer.json` referencing
`default_devcontainer_image` so `coder_devcontainer.repo` still has a
valid config to build against — a blank workspace works out of the box,
no separate fallback flag needed. To develop cade itself instead
(dogfooding/contributing), push (or re-push) the template with the
override:

```bash
coder templates push devcontainer -d coder/templates/devcontainer \
  --var repo_url=https://github.com/tbrandenburg/cade.git --yes
```

## Why Docker-in-Docker, not docker-outside-of-docker

An earlier version of this template bind-mounted the host's
`/var/run/docker.sock` into the workspace container so `devcontainer up`
could create the inner container next to it
("docker-outside-of-docker"). A live E2E found this fundamentally broken:
`docker_volume.home_volume` is a named Docker volume, not a real host path,
so when the `devcontainer` CLI asked the *shared host daemon* to bind-mount
the cloned repo into a sibling inner container, the host resolved that path
against the real host filesystem, where it doesn't exist. Coder's own docs
also explicitly call host-socket mounting "strongly discouraged" because
workspaces then compete for control of the devcontainers. This template now
follows Coder's own reference pattern
(`coder/examples/templates/docker-devcontainer` upstream) instead: the
workspace container runs `privileged = true` and starts its own nested
`dockerd` (via `sudo service docker start` in the agent's `startup_script`),
backed by a dedicated `docker_volume` mounted at `/var/lib/docker` so the
devcontainer image/layer cache survives restarts. See
`docs/devcontainer-security-notes.md` for the full incident writeup.

## Build the bootstrap image first

```bash
make devcontainer-workspace-build   # tags cade/devcontainer-bootstrap:latest
```

## Parameters (must ALL be passed explicitly on `coder create --parameter`)

| Parameter | Default | Notes |
|---|---|---|
| `github_token` | `""` | Optional, for private `repo_url` clones (injected via `GIT_ASKPASS`, see `coder/devcontainer/Dockerfile`). |
| `agent_capable` | `false` | Same autostop-relaxation semantics as docker-workspace. |
| `devcontainer_path` | `.devcontainer` | Path (relative to the cloned repo root) containing `devcontainer.json`. Its *parent* directory is passed to `coder_devcontainer.workspace_folder`. |

Example:

```bash
coder templates push devcontainer -d coder/templates/devcontainer --yes
coder create <owner>/<name> --template devcontainer --yes \
  --parameter github_token= --parameter agent_capable=false \
  --parameter devcontainer_path=examples/hello-service/.devcontainer
```

## MVP scope / known limitations

- `docker_volume.home_volume` and `docker_volume.docker_volume` use the same
  fixed-name + `ignore_changes` pattern as `docker-workspace`, so Durability
  Test 3 (AGENTS.md) applies here too — but `coder delete` still destroys
  them (see AGENTS.md Lessons Learned).
- The nested daemon means devcontainer builds are not shared across
  workspaces (unlike a shared host daemon) — each workspace pays its own
  image-pull/build cost on first start, cached afterward in its own
  `docker_volume.docker_volume`.

## Automatic `host.docker.internal` mapping for cloned repos (Issue #114)

Whether `.devcontainer/devcontainer.json` comes from a non-empty `repo_url`
clone or the built-in blank-workspace bootstrap, `coder_script` runs before
`coder_devcontainer.repo` builds and merges a
`--add-host=host.docker.internal:<resolved-ip>` entry into its `runArgs`
array (idempotent — skipped if already present), using `jsonc-parser` so
any existing comments/formatting in the repo's own file are preserved. This
fixes the inner Coder Agent's permanent "connecting" hang (Issue #107);
users no longer need to add this entry themselves.
