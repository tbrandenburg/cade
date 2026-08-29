# Workspace image for the `embedded-linux` Coder template (Milestone M6).
#
# Layers on top of the standard `cade/coder-workspace` image (same
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
FROM cade/coder-workspace:latest

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

# Milestone M7: sccache compiler cache, pinned release binary (no apt
# package for this arch/distro combo). `SCCACHE_DIR`/`SCCACHE_BASEDIRS` are
# baked into the image (not left to per-workspace config) so every
# `embedded-linux` workspace agrees on both — see cache/sccache/README.md
# for the absolute-path cache-key gotcha this avoids. The cache directory
# itself is a named Docker volume mounted at this path by
# coder/templates/embedded-linux/main.tf, shared across workspace
# instances (unlike the per-workspace home volume).
ARG SCCACHE_VERSION=0.17.0
RUN curl -fsSL \
      "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
      -o /tmp/sccache.tar.gz \
    && tar -xzf /tmp/sccache.tar.gz -C /tmp \
    && install -m 0755 "/tmp/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache" /usr/local/bin/sccache \
    && rm -rf /tmp/sccache.tar.gz "/tmp/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl"

ENV SCCACHE_DIR=/home/coder/.cache/sccache \
    SCCACHE_BASEDIRS=/home/coder/project

# Pre-create and chown the cache dir as the `coder` user: Docker populates a
# freshly created named volume from whatever already exists at the image's
# mount point (including ownership), so the volume mounted here by
# coder/templates/embedded-linux/main.tf comes up writable by `coder`
# instead of root-owned.
RUN mkdir -p /home/coder/.cache/sccache && chown -R coder:coder /home/coder/.cache

USER coder
