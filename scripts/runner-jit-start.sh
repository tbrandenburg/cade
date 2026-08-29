#!/usr/bin/env bash
# Generate a JIT (just-in-time / ephemeral) GitHub Actions runner
# configuration and start ONE self-hosted runner container that executes
# exactly one job, then exits and auto-deregisters (Milestone M2).
#
# Prefers JIT registration over a long-lived persistent runner per the
# plan/GitHub's hardening guide — no registration token or long-lived
# runner identity persists after the job completes.
#
# Requires: `gh` authenticated with a token that has `repo` (or
# `admin:org`, for an org runner) scope on the target repository, and the
# runner image built (`make runner-build`).
set -euo pipefail

REPO="${RUNNER_REPO:-tbrandenburg/cade}"
IMAGE="${RUNNER_IMAGE:-cade/runner:latest}"
RUNNER_NAME="private-lab-$(date +%s)"

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

echo "Requesting JIT config for repo=${REPO} name=${RUNNER_NAME} ..."
JIT_CONFIG="$(gh api "repos/${REPO}/actions/runners/generate-jitconfig" \
  -X POST \
  -f "name=${RUNNER_NAME}" \
  -F "runner_group_id=1" \
  -f "labels[]=self-hosted" \
  -f "labels[]=linux" \
  -f "labels[]=private-lab" \
  -f "labels[]=docker" \
  -f "work_folder=_work" \
  --jq '.encoded_jit_config')"

if [ -z "${JIT_CONFIG}" ] || [ "${JIT_CONFIG}" = "null" ]; then
  echo "ERROR: failed to obtain a JIT config from the GitHub API." >&2
  exit 1
fi

echo "Starting ephemeral runner container '${RUNNER_NAME}' ..."
docker run \
  --name "${RUNNER_NAME}" \
  --rm \
  --network platform-workspaces \
  -e DOCKER_HOST="tcp://runner-docker-proxy:2375" \
  "${IMAGE}" \
  --jitconfig "${JIT_CONFIG}"
