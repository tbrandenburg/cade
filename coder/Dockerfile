# Workspace image for the `docker-workspace` Coder template (Milestone M3).
#
# Contents: git, curl, build-essential, Python, Node.js, GitHub CLI, Docker
# CLI, and a project-specific non-root user ("coder").
#
# M9 adds bubblewrap, socat, ripgrep, and tmux, plus the `opencode`/`pi`
# agent CLIs and Anthropic's Sandbox Runtime (`srt`), to support the
# Agent/Harness Plane (LLM/agent harness integration).
FROM ubuntu:24.04

ARG USERNAME=coder
ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_MAJOR=20
# Pinned OpenCode CLI version (Issue #43). Must stay within Omnigent's
# opencode-native harness supported range [1.17.7, 1.19.0) -- re-check this
# range whenever Omnigent is upgraded, and bump with
# `--build-arg OPENCODE_VERSION=<x.y.z>` rather than editing the Dockerfile.
ARG OPENCODE_VERSION=1.18.25

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
    && apt-get install -y --no-install-recommends \
      bubblewrap \
      socat \
      ripgrep \
      tmux \
    && rm -rf /var/lib/apt/lists/*

# M9: Agent/Harness Plane CLIs — `opencode` and `pi`, the two supported
# harnesses for this platform (Rule: install both, not optional), plus
# Anthropic's Sandbox Runtime (`srt`) to wrap them in an OS-level sandbox.
# Installed system-wide (not per-user) so both are on PATH for the
# non-root `coder` user created below.
RUN npm install -g @anthropic-ai/sandbox-runtime @earendil-works/pi-coding-agent \
    && curl -fsSL https://opencode.ai/install | bash -s -- --version ${OPENCODE_VERSION} \
    && mv /root/.opencode/bin/opencode /usr/local/bin/opencode \
    && rm -rf /root/.opencode

# --- JupyterLab (Issue #60) -------------------------------------------------
# Own venv, not the system Python: Ubuntu 24.04 is PEP-668 "externally
# managed", so a bare `pip install` fails, and --break-system-packages would
# put jupyter's dep tree in the same environment as the workspace's own
# project deps. Symlinked onto PATH for every user/shell (non-login child
# processes never source /etc/profile).
ARG JUPYTERLAB_VERSION=4.4.5
RUN python3 -m venv /opt/jupyter \
    && /opt/jupyter/bin/pip install --no-cache-dir "jupyterlab==${JUPYTERLAB_VERSION}" \
    && ln -s /opt/jupyter/bin/jupyter /usr/local/bin/jupyter \
    && ln -s /opt/jupyter/bin/jupyter-lab /usr/local/bin/jupyter-lab

# --- Node-RED (Issue #60) ---------------------------------------------------
# Node.js 20 is already installed above (NODE_MAJOR). Palette packages are
# installed globally here rather than into the userDir, so a fresh
# /home/coder/.node-red on a brand-new home volume needs zero network access
# to boot with the dashboard + agent nodes already available.
# NODE_RED_AGENTS_VERSION pinned to >=0.3.8: earlier 0.3.x releases declared
# engines.node >=22 (Issue #63) despite having no Node-22-only API usage;
# 0.3.8 relaxes engines.node to >=20, matching this image's actual Node
# major version and clearing the prior EBADENGINE warning at install time.
ARG NODE_RED_VERSION=4.1.0
ARG NODE_RED_DASHBOARD_VERSION=1.31.0
ARG NODE_RED_AGENTS_VERSION=0.3.8
RUN npm install -g --no-audit --no-fund \
      "node-red@${NODE_RED_VERSION}" \
      "@flowfuse/node-red-dashboard@${NODE_RED_DASHBOARD_VERSION}" \
      "@tbrandenburg/node-red-agents@${NODE_RED_AGENTS_VERSION}" \
    && mkdir -p /opt/node-red
COPY workspace-apps/node-red-settings.js /opt/node-red/settings.js

# Omnigent host CLI (Issue #75, porting Issue #43's agent-workspace
# integration to docker-workspace) — PyPI `omnigent` package only, mirrored
# verbatim from `coder/agent-workspace/Dockerfile`'s existing block (see
# that file's comment for the full rationale: not the upstream
# omnigent-sandbox `deploy/docker/Dockerfile.host` image, own venv for
# isolation). Version MUST stay in lockstep with omnigent-server's pin in
# ../compose.yaml and within the OpenCode range OPENCODE_VERSION (above)
# supports. This is installed unconditionally at image-build time — the
# opt-in gating (Tier 2, `enable_omnigent` coder_parameter, default false)
# happens entirely in coder/templates/docker-workspace/main.tf's startup
# script, not here; a few extra MB in the image is an acceptable trade-off
# for keeping this Dockerfile a single shared artifact.
ARG OMNIGENT_VERSION=0.11.0
RUN python3 -m venv /opt/omnigent-venv \
 && /opt/omnigent-venv/bin/pip install --no-cache-dir "omnigent==${OMNIGENT_VERSION}" \
 && ln -s /opt/omnigent-venv/bin/omnigent /usr/local/bin/omnigent \
 && omnigent --version

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
