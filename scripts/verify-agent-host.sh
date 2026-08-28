#!/usr/bin/env bash
# verify-agent-host.sh — Confirm the VS Code Agent Host process is running and
# reachable over the coder-config-ssh-generated SSH host, independent of any
# VS Code window being open (Milestone M4).
#
# The Agent Host is started by VS Code's Agents window on first remote
# connect and is designed to keep running (and keep any active agent turn
# going) after the editor window/client disconnects. This script only checks
# that the process is alive and reachable over SSH — it does not start a
# session itself. Run `scripts/verify-ahp-session.sh` for an actual AHP
# protocol-level handshake check.
#
# Usage: scripts/verify-agent-host.sh <coder-ssh-host>
#   e.g. scripts/verify-agent-host.sh coder.my-workspace
#
# Exit code: 0 if the Agent Host process is found, 1 otherwise.

set -euo pipefail

HOST="${1:-}"
if [ -z "$HOST" ]; then
  echo "Usage: $0 <coder-ssh-host>" >&2
  echo "Run scripts/configure-coder-ssh.sh first, then pass e.g. coder.<workspace-name>." >&2
  exit 1
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

echo "Checking SSH reachability of $HOST..."
if ! ssh "${SSH_OPTS[@]}" "$HOST" true; then
  echo "FAIL: cannot reach $HOST over SSH. Run scripts/configure-coder-ssh.sh and retry." >&2
  exit 1
fi

# The Agent Host process is a VS Code CLI subprocess; VS Code's own naming
# has varied ("agent host", "agentHost", a "bootstrap-fork" child process).
# Match all known spellings rather than a single exact name.
PGREP_PATTERN='code[^ ]* agent host|agentHost|bootstrap-fork.*agent'

echo "Checking for a running Agent Host process on $HOST..."
if ssh "${SSH_OPTS[@]}" "$HOST" "pgrep -f -a '${PGREP_PATTERN}'"; then
  echo "PASS: Agent Host process found on $HOST."
  exit 0
fi

echo "FAIL: no Agent Host process found on $HOST." >&2
echo "This is expected if no Agents-window session has ever been started" >&2
echo "against this workspace yet — VS Code starts the Agent Host lazily on" >&2
echo "first remote connect, it is not part of the workspace startup script." >&2
exit 1
