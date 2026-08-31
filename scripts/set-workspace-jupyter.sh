#!/usr/bin/env bash
# set-workspace-jupyter.sh — Enable/disable the JupyterLab dashboard tile
# (Issue #60) on an EXISTING docker-workspace workspace. Thin wrapper
# around scripts/set-workspace-parameter.sh — see that script's header
# comment for the underlying `coder stop`/`start --always-prompt`
# mechanics and why `coder update` is deliberately never used.
#
# Usage:
#   scripts/set-workspace-jupyter.sh <owner>/<workspace> [true|false]
#   scripts/set-workspace-jupyter.sh <workspace> [true|false]   # current user
#
# Examples:
#   scripts/set-workspace-jupyter.sh alice/dev            # enable (default)
#   scripts/set-workspace-jupyter.sh alice/dev false      # disable

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <owner>/<workspace>|<workspace> [true|false]" >&2
  exit 1
fi

exec "${script_dir}/set-workspace-parameter.sh" "$1" enable_jupyter "${2:-true}"
