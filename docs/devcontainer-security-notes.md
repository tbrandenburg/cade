# devcontainer template security notes

Issue: GitHub #6 ("real devcontainer.json support as a workspace
blueprint"). This document is the up-to-date record of the template's
actual, shipped design and its accepted security tradeoff. See
`docs/security.md` for the cross-reference.

**Design history, for context:** the template originally used
docker-outside-of-docker (bind-mounting the host's `/var/run/docker.sock`
directly). A live E2E found that approach fundamentally broken — not just
risky — because `docker_volume.home_volume` is a named Docker volume, not
a real host path, so the *host's* Docker daemon (reached via the shared
socket) could never resolve the bind-mount paths the `devcontainer` CLI
asked it to create for the inner container. Researching Coder's own
official reference template
(`https://github.com/coder/coder/tree/v2.36.3/examples/templates/docker-devcontainer`)
confirmed this wasn't a one-off bug: Coder's own docs state mounting the
host socket is "strongly discouraged because workspaces will then compete
for control of the devcontainers." The template was rewritten to match
Coder's reference pattern instead, described below. The old
docker-outside-of-docker design is not used anywhere in this repo anymore.

## Current design: per-workspace nested Docker-in-Docker (DinD)

`coder/templates/devcontainer/main.tf`'s `docker_container.workspace` runs
`privileged = true` with its own nested `dockerd`, backed by a dedicated
`docker_volume.docker_volume` mounted at `/var/lib/docker` (alongside the
existing `docker_volume.home_volume` at `/home/coder`). The agent's
`startup_script` just starts and waits for this nested daemon
(`sudo service docker start` + poll `docker info`); cloning is handled by
the `registry.coder.com/coder/git-clone` module; the devcontainer itself
is declared via Coder's native `coder_devcontainer` resource instead of a
hand-rolled `devcontainer up`/`devcontainer exec` shell script.

This is **live-verified working end-to-end** (2026-08-29): a real
workspace correctly built and ran `examples/hello-service`'s
`.devcontainer/devcontainer.json` inside a real inner container, with the
cloned repo's bind-mount landing exactly where the devcontainer CLI
expected it (`workspaceMount":"type=bind,source=/home/coder/project,
target=/workspaces/project"` — no path-identity problem, by construction,
because the nested daemon and the cloned repo live in the *same*
container's filesystem view). `postCreateCommand` (`make build`) reported
`"outcome":"success"`. Durability Test 3 (`coder stop`/`start`, marker
file in `/home/coder`) also passed against this design.

## Blast radius of `privileged = true`

A privileged container is root-equivalent on the Docker host's kernel —
this is a real, accepted tradeoff, not a false sense of safety. It is,
however, **scoped per-workspace**: this nested daemon's own storage,
containers, and potential escape surface are confined to that one
workspace's `/var/lib/docker` volume, not shared with any other
workspace's daemon or with the *actual* host daemon (unlike the abandoned
host-socket design, where every workspace shared one daemon and could, in
principle, interfere with each other's inner containers — a correctness
problem as much as a security one). This matches Coder's own official
reference template's tradeoff exactly; it is the tradeoff Coder itself
ships and recommends for Docker-only deployments without a
Sysbox-capable host.

## Hardening options for a future issue (not implemented here)

The most secure alternative — **Sysbox** (or Coder's `envbox`, which
bundles it) — lets an *unprivileged* container run Docker-in-Docker
safely, with no `privileged` flag needed at all. It requires installing
the Sysbox runtime on the Docker host, which this repo's `AGENTS.md`
already flagged as unproven here: a prior sandboxing attempt
(`bwrap --unshare-user`) failed under this exact host's environment
(blocked unprivileged userns), so Sysbox would need its own from-scratch
feasibility check before being adopted, not assumed to work. Rootless
Podman and Kubernetes-oriented options (Envbox on GKE/EKS/AKS) don't apply
to this repo's single-Docker-host, no-Kubernetes deployment model at all.

Given those constraints, the current nested-DinD design — Coder's own
documented default for exactly this deployment shape — is treated as the
accepted baseline, not a placeholder; revisiting it is only worthwhile if
Sysbox is later verified compatible with the actual target host.

## Known remaining gaps (not blockers, tracked for follow-up)

- The dropped explicit fail-fast messages ("no devcontainer.json found",
  "unsupported dockerComposeFile") from the old manual-script design are
  not reproduced by `coder_devcontainer`'s own error surfacing — a
  missing/invalid `devcontainer.json` now fails with the devcontainer
  CLI's own (less custom-tailored, but still real) error output instead.
- Startup ordering between the git-clone module's `coder_script`, the
  agent's dockerd-start `startup_script`, and `coder_devcontainer`'s
  internal build script has no explicit `depends_on` wiring (matching
  Coder's own reference template, which doesn't wire this either) — not
  observed to race in the live E2E runs performed so far, but not
  exhaustively stress-tested across many concurrent workspace starts.
- Any `devcontainer.json` referencing an image that only exists in a
  *different* workspace's (or the host's) local Docker cache will fail to
  resolve, by design — the nested daemon's cache is cold on every fresh
  workspace. `examples/hello-service/.devcontainer/devcontainer.json` was
  updated to reference a real, publicly-pullable image
  (`mcr.microsoft.com/devcontainers/python:3`) instead of the repo-local
  `cade/coder-workspace:latest` for exactly this reason, and remains the
  **only** reference fixture actually live-`coder create`-verified against
  this design (PR #7).
  `examples/embedded-sim/.devcontainer/devcontainer.json` was updated
  (issue #10) to reference the public
  `mcr.microsoft.com/devcontainers/cpp:1-ubuntu-24.04` image instead of the
  repo-local `cade/embedded-linux-workspace:latest`, with a
  `postCreateCommand` that apt-installs the remaining cross-compile
  toolchain (`gcc-aarch64-linux-gnu`, `libc6-dev-arm64-cross` — cross-gcc
  alone is insufficient, see AGENTS.md lessons learned — `cmake`,
  `ninja-build`, `qemu-user`). A root-level `.devcontainer/devcontainer.json`
  was also added (previously missing entirely, so the template's default
  `devcontainer_path=".devcontainer"` had nothing to resolve against),
  referencing the same known-good `mcr.microsoft.com/devcontainers/python:3`
  base plus a `postCreateCommand` installing `make`, `docker.io`, and
  Terraform. Both new/updated images were confirmed independently
  resolvable with a direct `docker pull` in this environment (root cause
  of the original failure — "pull access denied, repository does not
  exist" — directly disproven for both). **Not yet live-`coder
  create`-verified**: no authenticated Coder CLI session was available in
  this environment (`coder whoami` returns "signed out"), matching the
  prior AGENTS.md lesson learned for new-template E2E checks — a real
  `coder create --template devcontainer --parameter
  devcontainer_path=examples/embedded-sim/.devcontainer` (and the
  equivalent root-fixture run) is still needed as a follow-up before these
  two fixtures reach the same evidence bar as `hello-service`.


