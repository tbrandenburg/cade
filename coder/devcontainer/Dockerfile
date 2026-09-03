# Bootstrap ("outer") image for the `devcontainer` Coder template. Contains
# what is needed for the Coder agent to run a nested (per-workspace)
# Docker-in-Docker daemon plus `devcontainer up`/`exec` against a repo's own
# `.devcontainer/devcontainer.json`: git, curl, the full Docker *engine*
# (dockerd, not just the CLI -- the container runs `privileged = true` and
# starts its own nested daemon instead of bind-mounting the host's socket;
# see coder/templates/devcontainer/main.tf and
# docs/devcontainer-security-notes.md for why), Node.js, and
# `@devcontainers/cli`. The *inner* container — built from the cloned repo's
# own devcontainer spec — is where the actual toolchain lives; keep this
# image deliberately thin. Modelled on coder/Dockerfile (docker-workspace
# template), reusing its CA-bundle and uid/gid-1000 user patterns verbatim.
FROM ubuntu:24.04

ARG USERNAME=coder
ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_MAJOR=20

# Optional corporate/TLS-intercepting-proxy CA bundle. Passed as a BuildKit
# secret (never a build arg or COPY) so it never lands in an image layer:
#   make devcontainer-workspace-build CACERT=/path/to/ca-bundle.pem
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
      jq \
      sudo \
      openssh-client \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && curl -fsSL https://get.docker.com | sh \
    && rm -rf /var/lib/apt/lists/*

# `@devcontainers/cli` is the reference implementation of the devcontainer
# spec, used by the template's startup script to `up`/`exec` against the
# cloned repo's own `.devcontainer/devcontainer.json`.
RUN npm install -g @devcontainers/cli

# `jsonc-parser` (the tiny, dependency-free package VS Code itself uses for
# comment/formatting-preserving JSONC edits) as its own explicit global
# install -- @devcontainers/cli is shipped as a single webpacked `dist` file
# whose bundled copy is NOT resolvable via `require('jsonc-parser')` from a
# separate script (Issue #114). Used by merge-devcontainer-runargs.js below
# to surgically inject a host.docker.internal runArg into a cloned repo's
# own .devcontainer/devcontainer.json without a naive/corrupting jq-or-regex
# edit.
RUN npm install -g jsonc-parser

# npm's global install location isn't on Node's default module resolution
# path for a script invoked as `node /usr/local/bin/...`; NODE_PATH makes
# `require('jsonc-parser')` in merge-devcontainer-runargs.js resolve there.
ENV NODE_PATH=/usr/lib/node_modules

COPY merge-devcontainer-runargs.js /usr/local/bin/merge-devcontainer-runargs.js

# Referenced by GIT_ASKPASS in coder/templates/devcontainer/main.tf's
# coder_agent.env -- the `git-clone` registry module has no token/auth input
# of its own (it only runs `git clone`), so credential injection for
# private `repo_url` clones has to happen via the ambient git environment.
RUN printf '#!/bin/sh\necho "$GITHUB_TOKEN"\n' > /usr/local/bin/git-askpass.sh \
    && chmod +x /usr/local/bin/git-askpass.sh

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
