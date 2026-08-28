#!/usr/bin/env bash
# configure-coder-ssh.sh — Bridge Coder workspaces to AHP via SSH (Milestone M4).
#
# Regenerates the local SSH config so every Coder workspace becomes reachable
# as a normal SSH host (e.g. `ssh coder.<workspace-name>`), which is what VS
# Code's Remote Agent Session feature (Agents window → AHP over SSH) connects
# through. Runs non-interactively so it can be used in scripts/CI as well as
# by hand.
#
# Usage: scripts/configure-coder-ssh.sh
# Requires: `coder` CLI already logged in (`coder login <url>`).

set -euo pipefail

if ! command -v coder >/dev/null 2>&1; then
  echo "ERROR: 'coder' CLI not found on PATH. Install it first: https://coder.com/docs/install" >&2
  exit 1
fi

echo "Regenerating SSH config for Coder workspaces..."
coder config-ssh --yes

echo "Done. Workspaces are reachable as: ssh coder.<workspace-name>"
