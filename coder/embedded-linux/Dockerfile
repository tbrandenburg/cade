# Workspace image for the `embedded-linux` Coder template (Milestone M6).
#
# Layers on top of the standard `devenv-cloud/coder-workspace` image (same
# base, agent CLIs, non-root `coder` user) with an embedded-style
# cross-compilation toolchain: cmake, ninja, an aarch64 cross-gcc plus its
# target libc headers/libs, and qemu-user (userspace emulation only — no
# MMIO/interrupts/boot process, see examples/embedded-sim/README.md) to run
# the cross-compiled binary. Every added package is version-pinned so the
# toolchain has a reproducible identity (repo revision + Dev Container
# revision + this image's digest), per M6's "Toolchain Provenance"
# requirement. Pushing the resulting digest to a local OCI registry is
# introduced in M7; until then, the digest is recorded manually in
# docs/milestone-reports/M6-embedded.md.
FROM devenv-cloud/coder-workspace:latest

USER root

# Optional corporate/TLS-intercepting-proxy CA bundle, same pattern as
# ../Dockerfile (Milestone M3) — a no-op on unrestricted networks.
RUN --mount=type=secret,id=cacert \
    if [ -s /run/secrets/cacert ]; then \
      cp /run/secrets/cacert /usr/local/share/ca-certificates/corporate-ca.crt \
      && update-ca-certificates; \
    fi

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      cmake=3.28.3-1build7 \
      ninja-build=1.11.1-2 \
      gcc-aarch64-linux-gnu=4:13.2.0-7ubuntu1 \
      libc6-dev-arm64-cross=2.39-0ubuntu8cross1 \
      qemu-user=1:8.2.2+ds-0ubuntu1.18 \
      qemu-user-static=1:8.2.2+ds-0ubuntu1.18 \
    && rm -rf /var/lib/apt/lists/*

USER coder
