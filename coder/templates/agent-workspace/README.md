# `agent-workspace` Coder template (Issue #13 Task 7)

Provisions a workspace type intended specifically for long-running Coder
Agents sessions. Layers on top of `cade/coder-workspace:latest` (the
`docker-workspace` base image) with the OSS `boundary` network-isolation CLI
added, so agent harnesses can have their outbound network access
constrained/audited.

## Contents

- `main.tf` — same shape as `coder/templates/docker-workspace/main.tf`
  (`coder_agent`, code-server module, `docker_volume` persistent
  `/home/coder`, `docker_container`), plus first-boot-only, non-clobbering
  `boundary`-wrapped harness aliases (`boundary-opencode`, `boundary-pi`)
  added to `~/.bashrc`.
- `variables.tf` — `docker_socket` (optional Docker socket override) and
  `workspace_image` (pre-built image tag; defaults to
  `cade/agent-workspace:latest`). `repo_url` (repository to auto-clone;
  empty by default — bring your own project) is a `coder_parameter` in
  `main.tf`, not a variable — see below.

## Parameters

- `github_token` — optional token to clone `repo_url` when it is not
  publicly readable. GitHub-specific by design (see "Bring your own
  project" below) — same as `docker-workspace`.
- `agent_capable` — same autostop-relaxation parameter as `docker-workspace`,
  but **defaults to `true`** here (this template exists specifically for
  long-running unattended Agent Host / Coder Agents sessions, not for
  human-only, editor-attended work).

## Bring your own project (default) vs. dogfooding cade

By default `repo_url` is empty and `coder create` gives you a blank
`/home/coder/project` directory. To develop cade itself instead
(dogfooding/contributing), pass the override explicitly.

`repo_url` is a `coder_parameter` (same mechanism as `github_token`), so it
is genuinely settable per workspace via `--parameter` at `coder create`
time — different concurrent workspaces from the same template can clone
different repositories:

```bash
coder create <owner>/<name> --template agent-workspace --yes \
  --parameter repo_url=https://github.com/tbrandenburg/cade.git
```

`github_token`/`data.coder_external_auth.github` are named/scoped for
GitHub specifically, even though `repo_url` itself is a fully generic
HTTPS URL — public-repo cloning already works against any git host today
(GitLab, Bitbucket, self-hosted Gitea, etc.); only *authenticated* cloning
is GitHub-scoped, deliberately, rather than adding speculative
multi-provider auth support before it's actually needed.

## No LLM provider credentials

Coder Agents runs the AI loop in the control plane (see `coder/ai/`); this
workspace intentionally never receives an LLM provider API key in
`coder_agent.env`. If a future harness genuinely needs one, that decision
must be made explicitly and documented here — do not silently add one.

## Private-repo cloning (Issue #105)

The manual `github_token` fallback path (used when the workspace owner's
GitHub OAuth account isn't linked — the `coalesce()` in `GITHUB_TOKEN`
falls through to it) has been **live-verified**: created a throwaway
private github.com repo, minted a token, `coder create ... --parameter
github_token=<PAT> --parameter repo_url=<private-url>` with no OAuth link,
confirmed the cloned content matched byte-for-byte. No code change
needed for github.com. See `docker-workspace/README.md`'s Issue #105
section for the same finding and the open gitlab.com gap (not tested in
this pass — no credentials available); it applies identically here since
both templates share the exact same askpass mechanism.

## Build the workspace image first

Coder only uploads this template directory to the provisioner, not the
repository root, so the workspace image cannot be built inline from
`../../Dockerfile`. Build and tag it on the Docker host Coder uses **before**
pushing or using this template:

```bash
make agent-workspace-build                       # unrestricted network
make agent-workspace-build CACERT=/path/to/ca.pem # behind a MITM proxy
```

This produces `cade/agent-workspace:latest`, the default value of
`workspace_image`. It depends on (and will also (re)build, cache-hit,
near-instant unless changed) `cade/coder-workspace:latest`.

## Push a template revision

```bash
coder templates push agent-workspace \
  --directory coder/templates/agent-workspace
```

Per Coder's security best practices, push from CI using a dedicated
non-human account with the minimum required role — do not grant Template
Admin broadly, and never inline credentials in the `.tf` files (Coder
persists template versions indefinitely). Pass credentials via `TF_VAR_*`
environment variables or Coder parameters instead.

## Persistent home volume

`docker_volume.home_volume` is mounted at `/home/coder` and is the only
directory that survives a workspace container replace. It is referenced by
its fixed `name` string (not only via the Terraform resource) in
`docker_container.volumes`, and `lifecycle { ignore_changes = all }` is set
— both required for the volume to survive `coder stop`/`coder start` (see
`AGENTS.md`'s "Coder / Terraform / Docker" lessons: `ignore_changes = all`
alone does not survive `coder delete`; a fixed-name reference is what
actually matters for Durability Test 3).

## Known gaps / follow-up (not this step)

- `boundary`'s allow-list `config.yaml` is not wired in yet — see the
  `TODO(Task 8)` comment in `main.tf`'s startup script for exactly where it
  hooks in.
- `.mcp.json` wiring for lab-sim/other MCP servers is not wired in yet —
  see the `TODO(Task 8b)` comment immediately after the Task 8 one.
- `coder/agent-workspace/Dockerfile` installs `boundary` via its upstream
  `install.sh` pinned to a specific `--version`, but that installer has no
  checksum-verification mechanism (unlike this repo's `runner/Dockerfile`
  pattern of a pinned digest + `sha256sum -c`) — see the Dockerfile's
  comment for detail.

## Corporate CA bundle

If the Coder host sits behind a MITM/TLS-intercepting proxy, build the
workspace image with the optional CA bundle:

```bash
make agent-workspace-build CACERT=/path/to/ca-bundle.pem
```
