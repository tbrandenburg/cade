#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for component in launch relay seed; do
  expected=$(sha256sum "$root/coder/omnigent/$component.py" | cut -d ' ' -f1)
  actual=$(docker run --rm --network none --entrypoint sha256sum \
    "${WORKSPACE_IMAGE:-cade/coder-workspace:latest}" "/opt/cade/omnigent-$component.py" | cut -d ' ' -f1)
  if [ "$expected" != "$actual" ]; then
    echo "Stale workspace image: omnigent-$component.py differs from repository" >&2
    exit 1
  fi
done
docker run --rm --network none \
  --mount "type=bind,src=$root/tests/coder-omnigent-launch.py,dst=/tmp/test_launch.py,readonly" \
  --mount "type=bind,src=$root/tests/coder-omnigent-readiness.py,dst=/tmp/test_readiness.py,readonly" \
  --mount "type=bind,src=$root/coder/templates/docker-workspace/main.tf,dst=/tmp/docker.tf,readonly" \
  --mount "type=bind,src=$root/coder/templates/agent-workspace/main.tf,dst=/tmp/agent.tf,readonly" \
  --entrypoint /opt/omnigent-venv/bin/python3 \
  --workdir /tmp \
  "${WORKSPACE_IMAGE:-cade/coder-workspace:latest}" -m unittest -v test_launch test_readiness
