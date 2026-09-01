#!/usr/bin/env bash
# set-workspace-omnigent.sh — Enable/disable the Omnigent Chat dashboard
# tile (Issue #75) on an EXISTING docker-workspace workspace. Thin wrapper
# around scripts/set-workspace-parameter.sh — see that script's header
# comment for the underlying `coder stop`/`start --always-prompt`
# mechanics and why `coder update` is deliberately never used. Purely for
# discoverability/consistency with set-workspace-jupyter.sh/
# -nodered.sh/-temporal-tile.sh — not functionally required, since
# `scripts/set-workspace-parameter.sh <owner>/<ws> enable_omnigent <value>`
# already works generically.
#
# Prerequisite: omnigent-db/omnigent-server must already be up
# (`docker compose up -d omnigent-db omnigent-server` +
# `make omnigent-bootstrap`) for the resulting tile to reach a working
# chat session — see coder/templates/docker-workspace/README.md.
#
# Usage:
#   scripts/set-workspace-omnigent.sh <owner>/<workspace> [true|false]
#   scripts/set-workspace-omnigent.sh <workspace> [true|false]   # current user
#
# Examples:
#   scripts/set-workspace-omnigent.sh alice/dev            # enable (default)
#   scripts/set-workspace-omnigent.sh alice/dev false      # disable

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <owner>/<workspace>|<workspace> [true|false]" >&2
  exit 1
fi

exec "${script_dir}/set-workspace-parameter.sh" "$1" enable_omnigent "${2:-true}"
