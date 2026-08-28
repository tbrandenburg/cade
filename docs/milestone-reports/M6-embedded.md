# M6 Embedded Simulation Workspace — Milestone Report

Evidence captured for Phase 3 / Milestone M6 (Embedded Simulation
Workspace), per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2
and `docs/plan/plan.md` (M6 section).

- **Timestamp (UTC):** 2026-08-28T17:39Z
- **Environment:** local Coder server (`ghcr.io/coder/coder:v2.36.3`),
  new `embedded-linux` template pushed from `coder/templates/embedded-linux`,
  workspace image `devenv-cloud/embedded-linux-workspace:latest` built
  locally from `coder/embedded-linux/Dockerfile` on top of
  `devenv-cloud/coder-workspace:latest`, authenticated as `admin`.

## What was built

- `examples/embedded-sim/` — a small C "firmware" example: `checksum.c`
  implements Fletcher-16, `main.c` validates a simulated sensor frame
  against a pinned known-good checksum (self-check pattern), and
  `tests/test_checksum.c` unit-tests the checksum function on the host with
  known-answer test vectors plus a corruption-detection regression check.
  `CMakeLists.txt` builds both a native `test_checksum` and a `firmware`
  target; `cmake/aarch64-toolchain.cmake` cross-compiles the latter for
  `aarch64-linux-gnu` when supplied via `CMAKE_TOOLCHAIN_FILE`. The
  `Makefile` exposes `configure`/`build`/`test` (native host build + ctest)
  and `simulate` (cross-compiles for aarch64, runs the binary under
  `qemu-aarch64` — qemu-user, not qemu-system; see the example's
  `README.md` for the userspace-emulation-only caveat this milestone calls
  out).
- `coder/embedded-linux/Dockerfile` — layers a pinned aarch64
  cross-compilation toolchain (cmake, ninja-build, gcc-aarch64-linux-gnu,
  libc6-dev-arm64-cross, qemu-user, qemu-user-static — every package
  version-pinned) on top of the existing `devenv-cloud/coder-workspace`
  image, reusing the same optional `CACERT` BuildKit-secret pattern as
  Phase 1's M3 `coder/Dockerfile`.
- `coder/templates/embedded-linux/` — a second Coder template
  (`main.tf`/`variables.tf`/`README.md`), structurally identical to
  `docker-workspace` (M3), with `variables.tf`'s `workspace_image` default
  pointed at `devenv-cloud/embedded-linux-workspace:latest`.
- `Makefile` — new `embedded-workspace-build` target (depends on
  `coder-workspace-build` for the base layer), reusing the existing dirty
  git-tree guard and `CACERT` pass-through.
- `.gitignore` — ignores `examples/embedded-sim/build/` and `build-target/`
  (local/CI build output, not source).

## Toolchain provenance

`coder/embedded-linux/Dockerfile` pins every added package's exact apt
version rather than an unpinned "latest ubuntu + apt install":
`cmake=3.28.3-1build7`, `ninja-build=1.11.1-2`,
`gcc-aarch64-linux-gnu=4:13.2.0-7ubuntu1`,
`libc6-dev-arm64-cross=2.39-0ubuntu8cross1`,
`qemu-user=1:8.2.2+ds-0ubuntu1.18`, `qemu-user-static=1:8.2.2+ds-0ubuntu1.18`
(all current `noble`/`noble-updates` candidates as of this build).

- Base image digest (`devenv-cloud/coder-workspace:latest`):
  `sha256:93fff80e030697c623901b1435745f649ecdca60d4b157396a78ac58667a0699`
- Embedded-linux image digest
  (`devenv-cloud/embedded-linux-workspace:latest`):
  `sha256:390458eb63c380823bf93c727e0f748e7eecf94923e374ab6bb252924066aacd`

**Note:** M7 (local OCI registry, not yet implemented at the time of this
step) is where these digests should be pushed for content-addressable
pull rather than only tagged in the local Docker daemon. Until M7 lands,
this report is the recorded provenance instead.

## Validation Milestone M6 (real transcript)

```
$ make embedded-workspace-build
...
#7 writing image sha256:390458eb63c380823bf93c727e0f748e7eecf94923e374ab6bb252924066aacd
#7 naming to docker.io/devenv-cloud/embedded-linux-workspace:latest

$ coder templates push embedded-linux --directory coder/templates/embedded-linux --yes
...
The embedded-linux template has been created at Aug 28 19:38:04!

$ coder create admin/m6-embedded --template embedded-linux --yes \
    --parameter "github_token=" --parameter "agent_capable=false"
...
The m6-embedded workspace has been created at Aug 28 19:38:47!

$ docker exec coder-admin-m6-embedded cat /tmp/coder-startup-script.log
Cloning into '/home/coder/project'...

$ docker exec coder-admin-m6-embedded bash -lc '
    which gcc cmake ninja aarch64-linux-gnu-gcc qemu-aarch64
    cd /home/coder/project
    make -C examples/embedded-sim clean
    make -C examples/embedded-sim build
    make -C examples/embedded-sim test
    make -C examples/embedded-sim simulate'
/usr/bin/gcc
/usr/bin/cmake
/usr/bin/ninja
/usr/bin/aarch64-linux-gnu-gcc
/usr/bin/qemu-aarch64
...
[6/6] Linking C executable firmware
...
1/1 Test #1: checksum_test ....................   Passed    0.00 sec
100% tests passed, 0 tests failed out of 1
...
qemu-aarch64 -L /usr/aarch64-linux-gnu build-target/firmware
embedded-sim firmware: sensor frame checksum = 0xfa90
embedded-sim firmware: self-check OK
```

Artifact/toolchain summary:

- **Artifact filename:** `examples/embedded-sim/build-target/firmware`
  (70,576 bytes, ELF64 AArch64 `DYN` executable — verified via
  `readelf -h` inside the workspace: `Machine: AArch64`).
- **Compiler version:** `gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`
  (host `gcc` for `test_checksum`); `aarch64-linux-gnu-gcc (Ubuntu
  13.3.0-6ubuntu2~24.04.1) 13.3.0` (cross-compiler for `firmware`).
- **Image digest:** `sha256:390458eb63c380823bf93c727e0f748e7eecf94923e374ab6bb252924066aacd`
  (`devenv-cloud/embedded-linux-workspace:latest`).
- **Test output:** `checksum_test` — Passed (0.00 sec), 100% tests passed
  (1/1).
- **Simulation output:** `qemu-aarch64` (version 8.2.2, Debian
  `1:8.2.2+ds-0ubuntu1.18`) ran the cross-compiled `firmware` binary;
  stdout `embedded-sim firmware: sensor frame checksum = 0xfa90` /
  `embedded-sim firmware: self-check OK`; exit code `0`.

## Manual E2E Test M6

Performed for real against the live Coder deployment, no shell/API bypass
of the workspace lifecycle:

1. Pushed the new `embedded-linux` template (`coder templates push`, shown
   above) — first time this template has existed, so there was no prior
   workspace to delete for a "recreate" cycle; instead a fresh workspace
   was created directly (`coder create admin/m6-embedded --template
   embedded-linux --yes`), which is the equivalent clean-environment
   guarantee this test requires (a brand-new container, empty persistent
   volume, cloned repo from scratch).
2. Confirmed `/tmp/coder-startup-script.log` shows a real `git clone` (not
   a pre-existing volume) and `/home/coder/project` contains the repository
   root files.
3. Ran the full `make -C examples/embedded-sim clean/build/test/simulate`
   sequence inside the workspace container via `docker exec`
   (`coder-admin-m6-embedded`) — the same commands a developer would run
   from an attached VS Code/SSH terminal — and captured the real output
   above, including the qemu-user simulation producing the expected
   checksum and self-check pass.

## Sandbox constraint

Same as prior milestone reports: this is a non-interactive container
sandbox with no attached display, so the VS Code GUI step ("Coder → New
Workspace → embedded-linux" via the web UI) was driven through the
equivalent `coder create` CLI call against the same live Coder deployment,
not simulated or mocked.
