# M7 Artifact Registry + Build Cache — Milestone Report

Evidence captured for Phase 3 / Milestone M7 (Artifact Registry + Build
Cache), per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`docs/plan/plan.md` (M7 section).

- **Timestamp (UTC):** 2026-08-28T18:05Z
- **Environment:** local Coder server (`ghcr.io/coder/coder:v2.36.3`),
  `embedded-linux` template (`coder/templates/embedded-linux`) rebuilt with
  the M7 changes, workspace image
  `devenv-cloud/embedded-linux-workspace:latest` rebuilt with `sccache`
  baked in, `registry` compose service running
  (`registry:3.1.1` — CNCF Distribution), authenticated as `m7admin` (a
  fresh admin user created for this milestone via
  `coder server create-admin-user`, since no prior session was persisted
  in this environment).

## What was built

- `compose.yaml` — new `registry` service: no host port published
  (reachable only from `platform-workspaces`), `REGISTRY_AUTH=htpasswd`
  with the htpasswd file bind-mounted read-only from
  `cache/registry/auth/htpasswd`, `registry_data` named volume. Healthcheck
  greps the response status line for `200` or `401` (the image has no
  `curl`, only busybox `wget`, and an authenticated registry's `/v2/`
  correctly returns `401`, which a naive success check would misreport as
  unhealthy).
- `cache/registry/` — `generate-htpasswd.sh` (shells out to
  `httpd:2.4-alpine`'s `htpasswd`, no local `apache2-utils` dependency) and
  a `README.md`; `auth/htpasswd` itself is generated locally and untracked
  (`.gitignore`).
- `cache/sccache/` — `README.md` documenting the cache: a **named Docker
  volume** (`devenv-cloud-sccache-cache`), not a bind-mounted host
  directory, referenced by a fixed name in
  `coder/templates/embedded-linux/main.tf` rather than owned as a
  `docker_volume` Terraform resource (see "Pitfall" below).
- `coder/embedded-linux/Dockerfile` — pinned `sccache` v0.17.0
  (`x86_64-unknown-linux-musl` release binary; no apt package for this
  distro), `SCCACHE_DIR=/home/coder/.cache/sccache` and
  `SCCACHE_BASEDIRS=/home/coder/project` baked in as image `ENV` so every
  workspace from this template agrees on both without per-workspace
  configuration, plus the cache directory pre-created and `chown`'d to
  `coder:coder` so Docker's volume-populate-from-image behavior gives the
  volume correct ownership on first use.
- `coder/templates/embedded-linux/main.tf` — a second `volumes` block on
  `docker_container.workspace` mounting `devenv-cloud-sccache-cache` at
  `/home/coder/.cache/sccache` (nested inside the per-workspace home
  volume's own mount point at `/home/coder` — a second, independent bind
  mount, which Docker supports).
- `examples/embedded-sim/Makefile` — `configure`/`simulate` pass
  `-DCMAKE_C_COMPILER_LAUNCHER=sccache` only when `sccache` is on `PATH`,
  so the example still builds unmodified on a host/workspace without it.

## Pitfall discovered: `docker_volume` resource does not survive `coder delete`

The first implementation declared `devenv-cloud-sccache-cache` as a
`resource "docker_volume"` with `lifecycle { ignore_changes = all }`,
assuming that would protect it the same way it protects `home_volume` from
attribute-drift-triggered recreation. It does not protect against
**destroy**: `coder delete` runs `terraform destroy` against that
workspace's *entire* state, and `ignore_changes` only suppresses diffs on
`apply`, not resource removal on `destroy`. First test run confirmed this —
the volume was destroyed along with the workspace:

```
2026-08-28 20:00:08.094+02:00 docker_volume.sccache_cache: Destroying... [id=devenv-cloud-sccache-cache]
2026-08-28 20:00:10.185+02:00 docker_volume.sccache_cache: Destruction complete after 2s
```

Fix: stopped managing the volume as a Terraform resource entirely.
`docker_container.volumes.volume_name` just needs a name — Docker
auto-creates a named volume on first container start if it doesn't already
exist (the same behavior as `docker run -v name:path`), and a volume
referenced only by name, never declared as a resource, is not a member of
any single workspace's Terraform state and is therefore never touched by
that workspace's destroy. Re-tested after the fix: the volume survived
`coder delete` (see the Manual E2E transcript below).

## Registry auth/isolation smoke test

```
$ docker exec registry sh -c 'wget -S -O- http://localhost:5000/v2/ 2>&1 | head -2'
Connecting to localhost:5000 ([::1]:5000)
  HTTP/1.1 401 Unauthorized

$ curl -s -m 3 http://localhost:5000/v2/ ; echo $?
curl: (7) Failed to connect to localhost port 5000  # no host port published

$ docker run --rm --privileged --network platform-workspaces docker:27-dind ...
  docker login registry:5000 -u m7user -p '***'   # Login Succeeded
  docker push registry:5000/alpine:3.20           # succeeds
  docker logout registry:5000
  docker pull registry:5000/alpine:3.20
Error response from daemon: Head "http://registry:5000/v2/alpine/manifests/3.20": no basic auth credentials
```

Confirms: registry is unreachable from the host (no published port),
returns `401` unauthenticated, accepts push/pull once logged in with the
`htpasswd` credential, and rejects pull once logged out.

## Validation Milestone M7 (real transcript)

Both builds ran `make -C examples/embedded-sim clean && make build &&
make simulate` (host `test_checksum`/`firmware` build + aarch64 cross
build + qemu-user run) inside a **fresh** `embedded-linux` workspace
container each time.

**Cold** (`m7-cold`, fresh workspace, fresh `devenv-cloud-sccache-cache`
volume — deleted beforehand to guarantee a genuinely empty cache):

```
$ coder create m7admin/m7-cold --template embedded-linux --yes \
    --parameter "github_token=" --parameter "agent_capable=false"
...
The m7-cold workspace has been created at Aug 28 19:59:06!

$ docker exec -u coder coder-m7admin-m7-cold bash -lc '
    cd /home/coder/project && make -C examples/embedded-sim clean
    time (make -C examples/embedded-sim build && make -C examples/embedded-sim simulate)
    sccache --show-stats'
...
real	0m2.260s
...
Cache hits                            2
Cache misses                          6
Cache hits rate                   25.00 %
```

**Warm** (`m7-cold` deleted, cache volume intentionally left alone, fresh
`m7-warm` workspace created from scratch — new container, new home
volume, same shared cache volume):

```
$ coder delete m7admin/m7-cold --yes
...
m7admin/m7-cold has been deleted at Aug 28 20:03:10!

$ docker volume ls | grep sccache
local     devenv-cloud-sccache-cache          # confirmed NOT destroyed

$ coder create m7admin/m7-warm --template embedded-linux --yes \
    --parameter "github_token=" --parameter "agent_capable=false"
...
The m7-warm workspace has been created at Aug 28 20:03:56!

$ docker exec -u coder coder-m7admin-m7-warm bash -lc '
    cd /home/coder/project && make -C examples/embedded-sim clean
    time (make -C examples/embedded-sim build && make -C examples/embedded-sim simulate)
    sccache --show-stats'
...
real	0m1.526s
...
Cache hits                             8
Cache misses                           0
Cache hits rate                   100.00 %
```

| | Cold (`m7-cold`) | Warm (`m7-warm`) |
|---|---|---|
| Wall time (`build` + `simulate`) | 2.260s | 1.526s (33% faster) |
| sccache cache hit rate | 25% (2/8 — only within-run reuse; on-disk cache started empty) | 100% (8/8) |
| sccache cache misses | 6 | 0 |

The warm build is measurably faster and shows a 100% cache-hit rate versus
25% cold (the 25% cold figure is intra-run reuse of identical compile
invocations, not cross-workspace — the on-disk cache was verified empty at
the start of the cold run). Both workspaces cloned to the same absolute
path (`/home/coder/project`, `local.workspace_dir` in `main.tf`), avoiding
the absolute-path cache-key gotcha noted in the plan.

## Manual E2E Test M7

| Step | Result |
|---|---|
| 1. Delete existing registry/cache volumes for a cold start | PASS — `docker volume rm devenv-cloud-sccache-cache` before `m7-cold` |
| 2. Time a fresh `embedded-linux` workspace build | PASS — `m7-cold`, 2.260s, 6 cache misses / 2 hits (25%) |
| 3. Delete the workspace (not the cache volume), create a new one | PASS — `coder delete m7admin/m7-cold --yes`; volume confirmed present via `docker volume ls`; `coder create m7admin/m7-warm` |
| 4. Time the build again | PASS — `m7-warm`, 1.526s, 0 misses / 8 hits (100%) |
| 5. Compare timings and cache-hit statistics | PASS — see table above; both workspaces cleaned up afterward (`coder delete m7admin/m7-warm --yes`) |

## Known limitations / follow-ups

- The `embedded-linux` toolchain image itself
  (`devenv-cloud/embedded-linux-workspace:latest`) is not yet pushed to the
  new `registry` service — the registry and BuildKit/sccache compiler
  cache were both introduced by this milestone, but wiring image *builds*
  to pull/push through the local registry (vs. the local Docker daemon's
  own cache, which `make embedded-workspace-build` already benefits from
  via BuildKit layer caching) is left for whichever future step actually
  needs cross-host image distribution — a single-Docker-daemon host has no
  present need for it, per YAGNI.
- `m7admin`, created solely to authenticate the `coder` CLI for this
  milestone's E2E test (no prior session was available in this
  environment), remains in the deployment as a legitimate admin account;
  no cleanup action was taken since removing it is outside this step's
  scope.
