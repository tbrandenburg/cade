# Self-hosted GitHub Actions runner image (Milestone M2).
#
# Highest-security-sensitivity image in the plan: this container executes
# workflow jobs triggered from GitHub. Base OS image is pinned by digest
# (not just tag) and the final image carries no build-time-only packages.
#
# Registration model: JIT/ephemeral (`--jitconfig`, generated per-run by
# `scripts/runner-jit-start.sh`) — the container runs exactly one job then
# exits and auto-deregisters. There is no long-lived runner identity baked
# into this image or a running compose service for it.
#
# Docker access: this image does NOT bundle a Docker daemon and the
# container is never started with `/var/run/docker.sock` mounted directly
# (see docs/security.md). It talks to Docker exclusively through the
# `docker-socket-proxy` sidecar via `DOCKER_HOST=tcp://runner-docker-proxy:2375`,
# which allow-lists only the API calls this runner's smoke workflow needs.
#
# Rebuild/patch cadence: see docs/operations.md.
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG RUNNER_VERSION=2.337.0
ARG RUNNER_SHA256=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
ARG USERNAME=runner
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_ALLOW_RUNASROOT=0

# Optional corporate/TLS-intercepting-proxy CA bundle, same pattern as
# coder/Dockerfile (Phase 1 M3): passed as a BuildKit secret, never a build
# arg or COPY, so it never lands in an image layer.
#   make runner-build CACERT=/path/to/ca-bundle.pem
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=secret,id=cacert \
    if [ -s /run/secrets/cacert ]; then \
      cp /run/secrets/cacert /usr/local/share/ca-certificates/corporate-ca.crt \
      && update-ca-certificates; \
    fi

# Minimal runtime deps only: curl/tar to fetch+unpack the runner tarball,
# the runner's own installdependencies.sh needs a handful of libs, jq for
# the JIT-start script, and the Docker CLI (client only, no daemon) so
# workflow steps can talk to the socket-proxy sidecar.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      curl \
      tar \
      jq \
      git \
      sudo \
      docker.io \
    && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 already ships an `ubuntu` group/user at uid/gid 1000 — rename
# it instead of assuming groupadd/useradd will succeed (see AGENTS.md).
RUN if getent group ${USER_GID} > /dev/null; then \
      groupmod -n ${USERNAME} "$(getent group ${USER_GID} | cut -d: -f1)"; \
    else \
      groupadd --gid ${USER_GID} ${USERNAME}; \
    fi \
    && if getent passwd ${USER_UID} > /dev/null; then \
      usermod -l ${USERNAME} -d /home/${USERNAME} -m "$(getent passwd ${USER_UID} | cut -d: -f1)"; \
    else \
      useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USERNAME}; \
    fi \
    && usermod -aG docker ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

WORKDIR /home/${USERNAME}/actions-runner

RUN curl -fsSLo runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  runner.tar.gz" | sha256sum -c - \
    && tar xzf runner.tar.gz \
    && rm runner.tar.gz \
    && ./bin/installdependencies.sh \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/actions-runner

USER ${USERNAME}

# No ENTRYPOINT/CMD baked in with a persistent config: the container is
# always started with an explicit `--jitconfig` value (see
# scripts/runner-jit-start.sh), so `run.sh` performs exactly one job and
# exits — nothing to configure/deregister here.
ENTRYPOINT ["/home/runner/actions-runner/run.sh"]
