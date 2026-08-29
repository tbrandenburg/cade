# cache/registry — local OCI registry (Milestone M7)

Backs the `registry` service in `compose.yaml`: [CNCF
Distribution](https://distribution.github.io/distribution/) (Apache-2.0),
storing image layers in the `registry_data` named volume.

**Not open/unauthenticated.** The service publishes no host port — it is
reachable only from containers on the `platform-workspaces` Docker network
(the CNCF deployment guide's "internal network only" option) — and layers
htpasswd basic auth on top via `auth/htpasswd` (bind-mounted read-only into
the container at `/auth/htpasswd`). An authenticated registry returns `401`
from `/v2/` when unauthenticated, not `200` — the compose healthcheck
treats both as healthy.

## Generating credentials

`auth/htpasswd` is not committed (see `.gitignore`) — generate it locally
before `make up`:

```bash
./cache/registry/generate-htpasswd.sh <user> <password>
```

This shells out to `httpd:2.4-alpine`'s `htpasswd` via `docker run` (no
local `apache2-utils` dependency) and writes a bcrypt-hashed entry to
`cache/registry/auth/htpasswd`.

## Manual smoke test (push/pull through auth)

```bash
docker login localhost:5000   # from a container on platform-workspaces, e.g.:
docker run --rm --network platform-workspaces docker:27-cli \
  sh -c 'docker login registry:5000 -u <user> -p <password> \
    && docker pull alpine:3.20 \
    && docker tag alpine:3.20 registry:5000/alpine:3.20 \
    && docker push registry:5000/alpine:3.20'
```

## Toolchain image provenance (M6/M7)

`coder/embedded-linux/Dockerfile`'s image is tagged
`cade/embedded-linux-workspace:latest` locally (M6). Pushing it to
`registry:5000/embedded-linux-workspace` for content-addressable pull is
the natural next step once a workspace/CI job needs to pull it from
somewhere other than the local Docker daemon that built it; until then the
digest recorded in `docs/milestone-reports/M6-embedded.md` remains the
provenance record.
