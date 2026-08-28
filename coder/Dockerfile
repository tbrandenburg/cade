# Workspace image for the `docker-standard` Coder template (Milestone M3).
#
# Contents: git, curl, build-essential, Python, Node.js, GitHub CLI, Docker
# CLI, and a project-specific non-root user ("coder").
#
# M9 later adds bubblewrap, socat, and ripgrep to this same image to support
# sandboxing agent CLIs with `srt` (Anthropic Sandbox Runtime) — do not
# duplicate that work here.
FROM ubuntu:24.04

ARG USERNAME=coder
ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_MAJOR=20

# Optional corporate/TLS-intercepting-proxy CA bundle. Passed as a BuildKit
# secret (never a build arg or COPY) so it never lands in an image layer:
#   make build CACERT=/path/to/ca-bundle.pem
# On unrestricted networks this mount is empty and the step is a no-op.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=secret,id=cacert \
    if [ -s /run/secrets/cacert ]; then \
      cp /run/secrets/cacert /usr/local/share/ca-certificates/corporate-ca.crt \
      && update-ca-certificates; \
    fi

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      git \
      curl \
      ca-certificates \
      gnupg \
      build-essential \
      python3 \
      python3-pip \
      python3-venv \
      sudo \
      openssh-client \
      openssh-server \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && curl -fsSL https://get.docker.com | sh \
    && rm -rf /var/lib/apt/lists/*

RUN if getent group ${USER_GID} > /dev/null; then \
      groupmod -n ${USERNAME} "$(getent group ${USER_GID} | cut -d: -f1)"; \
    else \
      groupadd --gid ${USER_GID} ${USERNAME}; \
    fi \
    && if getent passwd ${USER_UID} > /dev/null; then \
      userdel -r "$(getent passwd ${USER_UID} | cut -d: -f1)" 2>/dev/null || true; \
    fi \
    && useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USERNAME} \
    && usermod -aG docker ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}
WORKDIR /home/${USERNAME}
