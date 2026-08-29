# devcontainer template security notes

Issue: GitHub #6 ("real devcontainer.json support as a workspace
blueprint"), hardening follow-up captured in issue #6b. This document
records a known, currently-accepted risk in `coder/templates/devcontainer/`
and defers the actual mitigation to a future issue — see
`docs/security.md` for the cross-reference and `AGENTS.md`'s "Must avoid"
scope for why this pass only documents rather than fixes the mount.

## Why the template bind-mounts `/var/run/docker.sock` directly

`coder/templates/devcontainer/main.tf`'s `docker_container.workspace`
bind-mounts the host's `/var/run/docker.sock` straight into the outer
workspace container (docker-outside-of-docker), rather than routing
through a restrictive socket-proxy the way `runner-docker-proxy` (M2) or
`build-docker-proxy` (issue #5 MVP) do for their own consumers.

The reason is functional, not an oversight: the outer container's
`startup_script` shells out to the `devcontainer` CLI
(`devcontainer up --workspace-folder ... --config ...`), which needs to:

- **build** an image from the cloned repo's `.devcontainer/Dockerfile`
  (or pull the `image:` it names),
- **create** a sibling inner container next to the outer one,
- **inspect/attach exec** into that inner container for the VS
  Code/code-server Remote-Containers experience,
- and later **remove** that inner container on workspace stop/teardown.

Every existing socket-proxy profile in this repo is deliberately
*narrower* than that. `runner-docker-proxy` (M2) allows `BUILD` but not
Docker Desktop for the AI-agent sandbox path (`gh-aw`'s MCP Gateway is
documented in `docs/security.md` as flatly incompatible with any
proxy, needing the real socket). `build-docker-proxy` (issue #5 MVP)
explicitly denies `BUILD`, `EXEC`, `VOLUMES`, and `NETWORKS` because its
one Activity only ever needs `docker run` against a pre-built image. The
devcontainer CLI's actual need set (`BUILD` + `EXEC` + create/remove
containers, at minimum) is close enough to "full access" that no
existing profile in this repo covers it, and standing up a new one
correctly — verified against the CLI's real API call sequence, not
guessed — is nontrivial scope, deferred here per the assigned task's
"do NOT change compose.yaml or add a socket-proxy service" constraint.

## Blast radius

A container holding an unrestricted `/var/run/docker.sock` bind-mount
has the practical equivalent of **root on the Docker host**, not just
"root in its own container": it can launch a new container with
`--privileged`, bind-mount the host's `/` into it, and read/write
anything the host's Docker daemon can reach — including every other
container's volumes, the Coder/Postgres/OpenBao data volumes, and (via a
privileged container) the host kernel itself. This is a well-known
container-escape-adjacent pattern (Docker's own docs and multiple CVE
writeups treat "give a container the host socket" as equivalent to
disabling container isolation entirely for that workload).

Concretely for this template: any code executed inside the outer
`coder-<owner>-<workspace>` container (the developer, an editor
extension, a supply-chain-compromised `devcontainer.json`/`Dockerfile`
in a cloned repo, or an Agent Host session running unattended per the
`agent_capable` parameter) can reach the host Docker API directly and is
not meaningfully sandboxed by the outer container boundary at all.

## Hardening options for a future issue (not implemented here)

1. **Rootless Docker-in-Docker via a `docker:dind` (or `docker:dind-rootless`)
   sidecar.** Give the workspace pod its own nested Docker daemon instead
   of the host's, so `devcontainer up` talks to a daemon whose blast
   radius is scoped to that one sidecar's storage volume. Tradeoffs:
   loses host layer-cache sharing across workspaces (slower first
   builds), needs `--privileged` (or fuse-overlayfs + rootless mode) on
   the sidecar itself, and doubles the container count per workspace.

2. **A sandboxed container runtime (gVisor `runsc` or Sysbox) for the
   *inner* devcontainer instead of the default `runc`.** Sysbox in
   particular is purpose-built to let an unprivileged container run
   Docker-in-Docker safely without a host socket mount at all (it
   virtualizes `/proc`, `/sys`, and syscalls the kernel would otherwise
   require `--privileged` for). Tradeoffs: a third-party runtime to
   install/maintain on the single Linux server (this repo's guideline is
   Docker-first, no extra infra), and per-`AGENTS.md`'s "Sandbox /
   security" lesson, this environment has already hit one blocked
   runtime-hardening attempt (`bwrap --unshare-user` failing under
   Docker/WSL2) — a new sandboxed runtime would need its own from-scratch
   feasibility check on the actual target host, not assumed to work.

3. **A purpose-built `devcontainer-docker-proxy` profile**, mirroring the
   `build-docker-proxy` pattern but reviewed specifically against the
   devcontainer CLI's actual HTTP call sequence, e.g. a starting point of
   `BUILD=1 EXEC=1 VOLUMES=0 NETWORKS=0 SWARM=0 SYSTEM=0` — narrower than
   the raw socket, but still needs verification (not guessed) against
   what `devcontainer up`/`exec`/`down` really call, since an
   under-scoped profile fails at runtime with a generic `403 Forbidden by
   administrative rules` (per this repo's own `tecnativa/docker-socket-
   proxy` lesson in `AGENTS.md`), not at template-authoring time.

None of the above is implemented in this pass — this document exists so
the tradeoff is visible and reviewable before a future issue picks one.

## Live E2E findings (2026-08-29) — two real bugs found and fixed, one architectural gap found and NOT fixed

A full live E2E was run against a freshly-reset Coder instance (fresh admin
user bootstrapped via `POST /api/v2/users/first`, since no cached session
existed in this environment): `coder templates push devcontainer`,
`coder create --template devcontainer`, inner/outer container inspection.

**Fixed (real bugs, not hypothetical):**

1. **Missing `docker` group GID passthrough.** The outer bootstrap
   container's non-root `coder` user had no access to the bind-mounted
   `/var/run/docker.sock` (`permission denied`, breaking every
   `docker`/`devcontainer` CLI call, confirmed via `docker exec ... docker
   ps` before/after). Fixed by adding a `docker_gid` Terraform variable
   (default `988`, override via `--variable docker_gid=$(getent group
   docker | cut -d: -f3)` per host) and `group_add` on
   `docker_container.workspace` in `main.tf`.

**Found, NOT fixed — genuine architectural gap, deferred to a follow-up issue:**

2. **Named-volume home directory is incompatible with docker-outside-of-docker
   bind-mounting the workspace into the *inner* container.**
   `docker_volume.home_volume` mounts at `/home/coder` as a Docker *named
   volume* (`coder-<id>-home`), which only exists inside the outer
   container's mount namespace — its real host-filesystem location is
   `/var/lib/docker/volumes/coder-<id>-home/_data`, not `/home/coder`.
   When the `devcontainer` CLI (running *inside* the outer container)
   asks the *host's* Docker daemon (via the shared socket) to bind-mount
   `/home/coder/project` into the inner container, the host daemon
   resolves that path against the **real host filesystem**, where it
   does not exist — confirmed live: `ls /home/coder/project` inside the
   outer container showed the cloned repo; `docker inspect
   coder-admin-devcontainer-e2e --format '{{range .Mounts}}...'` showed
   `/home/coder` mounted from `/var/lib/docker/volumes/coder-*-home/_data`
   (not `/home/coder` literally); the resulting inner container's
   `postCreateCommand` failed with `chdir to cwd ("/workspaces/project")
   ... no such file or directory`, and the real host gained an empty,
   spuriously-created `/home/coder/` directory as a side effect.
   This is the same fundamental "docker-outside-of-docker needs
   host-path-identity between outer and inner mounts" limitation that
   most `devcontainer`/DinD tooling documents as a known constraint of
   the *shared-socket* approach specifically (as opposed to a nested
   Docker-in-Docker daemon, hardening option 1 above, which does not
   have this problem since the sidecar's paths are its own).
   **Not fixed here** because the correct fix (bind-mounting a real host
   directory, e.g. `/var/lib/cade/devcontainer-workspaces/<workspace-id>`,
   instead of a named Docker volume for `/home/coder`) breaks this
   template's parity with the "docker volume, not directory" durability
   convention used by every other Coder template in this repo (see
   `AGENTS.md`'s Durability Test 3 guidance) and needs its own
   design/review pass, not a one-line patch.

