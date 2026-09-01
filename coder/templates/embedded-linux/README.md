# `embedded-linux` Coder template (Milestone M6)

Same Coder/Docker workspace mechanics as `docker-workspace` (Milestone M3):
repository auto-cloned into `/home/coder/project`, persistent per-workspace
home volume, code-server access. The only difference is the workspace
image, which adds a pinned embedded-style cross-compilation toolchain on
top of the standard image — see `../../embedded-linux/Dockerfile`.

## Contents

Identical `main.tf`/`variables.tf` structure to `../docker-workspace`,
except `variables.tf`'s `workspace_image` default points at
`cade/embedded-linux-workspace:latest` instead of
`cade/coder-workspace:latest`.

## Build the workspace image first

```bash
make embedded-workspace-build                       # unrestricted network
make embedded-workspace-build CACERT=/path/to/ca.pem # behind a MITM proxy
```

This builds `cade/coder-workspace:latest` first (the base layer),
then `cade/embedded-linux-workspace:latest` on top of it.

## Push a template revision

```bash
coder templates push embedded-linux \
  --directory coder/templates/embedded-linux \
  --var repo_url=https://github.com/<org>/cade.git
```

## Toolchain provenance

`../../embedded-linux/Dockerfile` pins every added package's exact apt
version (cmake, ninja-build, gcc-aarch64-linux-gnu,
libc6-dev-arm64-cross, qemu-user, qemu-user-static) instead of an
unpinned "latest ubuntu + apt install". The recorded image digest from the
last build is captured in `docs/milestone-reports/M6-embedded.md`. Once
M7's local OCI registry exists, this image should be pushed there instead
of only tagged locally.
