# cache/sccache — compiler cache (Milestone M7)

Documents the [`sccache`](https://github.com/mozilla/sccache) setup used by
the `embedded-linux` Coder workspace image
(`coder/embedded-linux/Dockerfile`) to speed up repeat cross-compiles of
`examples/embedded-sim` (M6).

## Where the cache actually lives

Not a bind-mounted host directory under this path — a **named Docker
volume**, `devenv-cloud-sccache-cache`, declared once in
`coder/templates/embedded-linux/main.tf` and mounted into every workspace
container's `/home/coder/.cache/sccache`. Unlike the per-workspace
`coder-<id>-home` volume (destroyed with the workspace), this volume's name
does not include the workspace ID, so it persists and is shared across
*every* workspace created from this template — exactly the "second fresh
workspace hits the first workspace's cache" scenario the Validation
Milestone M7 test requires. A bind-mounted host directory was considered
but rejected: it would tie the template to one Docker host's filesystem
layout and (per repository convention) a path checked into
`coder/templates/` must not embed a personal/host-specific absolute path.

## Cache-key gotcha: absolute paths

`sccache` cache keys embed absolute source paths by default. Two
workspaces from this template only hit each other's cache because both
clone the repository to the *same* absolute path
(`/home/coder/project` — `local.workspace_dir` in `main.tf`) — if that ever
diverges, set `SCCACHE_BASEDIRS` to normalize/strip the varying prefix
before it silently starts missing cache on every build. Both
`SCCACHE_DIR=/home/coder/.cache/sccache` and
`SCCACHE_BASEDIRS=/home/coder/project` are baked into
`coder/embedded-linux/Dockerfile` as image `ENV`, not left to per-workspace
configuration, so every workspace from this template agrees on both by
construction.

## Verifying cache hits

```bash
sccache --show-stats
```

`examples/embedded-sim/Makefile`'s `configure`/`simulate` targets pass
`-DCMAKE_C_COMPILER_LAUNCHER=sccache` (and, for the cross build,
`-DCMAKE_C_COMPILER_LAUNCHER=sccache` ahead of the toolchain's
`aarch64-linux-gnu-gcc`) whenever an `sccache` binary is on `PATH`,
falling back to a plain compile otherwise so the example still builds on a
workspace/host without it.
