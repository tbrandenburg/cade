# Workspace image for the `agent-workspace` Coder template (Issue #13 Task 7).
#
# Layers on top of the standard `cade/coder-workspace` image (same base,
# agent CLIs, non-root `coder` user) with the OSS `boundary` network-
# isolation CLI (https://github.com/coder/boundary) added, so long-running
# agent-harness sessions can have their outbound HTTP/HTTPS access
# constrained/audited.
FROM cade/coder-workspace:latest

USER root

# Optional corporate/TLS-intercepting-proxy CA bundle, same pattern as
# ../Dockerfile (Milestone M3) — a no-op on unrestricted networks.
RUN --mount=type=secret,id=cacert \
    if [ -s /run/secrets/cacert ]; then \
      cp /run/secrets/cacert /usr/local/share/ca-certificates/corporate-ca.crt \
      && update-ca-certificates; \
    fi

# `boundary` CLI, pinned to a specific released version via the upstream
# installer's `--version` flag (verified live against the script's actual
# source: `install.sh --version <tag>` is real and supported).
#
# KNOWN GAP: unlike this repo's `runner/Dockerfile` (pinned base image
# digest + `sha256sum -c` on the downloaded release archive), boundary's
# `install.sh` has NO checksum-verification mechanism at all — it downloads
# `https://github.com/coder/boundary/releases/download/$VERSION/boundary-<platform>.tar.gz`
# and extracts it directly with no published/verified hash to check against.
# Pinning the version string alone protects against unexpected upstream
# upgrades but not against a compromised release asset. Documented here
# rather than silently accepted; revisit if boundary later publishes
# checksums/sigstore attestations for its releases.
ARG BOUNDARY_VERSION=v0.10.0
RUN curl -fsSL https://raw.githubusercontent.com/coder/boundary/main/install.sh \
      | bash -s -- --version ${BOUNDARY_VERSION}

USER coder
