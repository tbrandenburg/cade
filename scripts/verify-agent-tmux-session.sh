#!/usr/bin/env bash
# verify-agent-tmux-session.sh — Prove process continuity for `opencode`/`pi`
# agent CLIs (Milestone M9), the equivalent of M4's AHP durability proof but
# for harnesses that do not run through the Agent Host.
#
# `opencode`/`pi` are not AHP adapters (see doc/plan/steps M9 section): they
# run as plain terminal processes inside the Coder workspace, wrapped by
# `srt`. Durability here means a detached `tmux` session keeps the wrapped
# harness process running whether or not a client (SSH terminal, VS Code) is
# attached — not AHP's multi-client sync or session list.
#
# This script:
#   1. Starts (or reattaches to) a named tmux session for a given worktree,
#      running a long-lived marker command standing in for a wrapped
#      `opencode`/`pi` session.
#   2. Records the marker process's PID.
#   3. Disconnects (closes the SSH connection).
#   4. Reconnects and confirms the *same* PID is still running inside the
#      *same* tmux session — proving the process survived the disconnect,
#      not just that a new one was started.
#
# Usage: scripts/verify-agent-tmux-session.sh <coder-ssh-host> <session-name> [worktree-dir]
#   e.g. scripts/verify-agent-tmux-session.sh coder.m9-e2e agent-session-001
#
# Exit code: 0 if the same PID survives a disconnect/reconnect cycle, 1
# otherwise.

set -euo pipefail

HOST="${1:-}"
SESSION="${2:-}"
WORKTREE_DIR="${3:-}"

if [ -z "$HOST" ] || [ -z "$SESSION" ]; then
  echo "Usage: $0 <coder-ssh-host> <session-name> [worktree-dir]" >&2
  echo "e.g. $0 coder.m9-e2e agent-session-001" >&2
  echo "Run scripts/configure-coder-ssh.sh first, then pass e.g. coder.<workspace-name>." >&2
  exit 1
fi

if [ -z "$WORKTREE_DIR" ]; then
  WORKTREE_DIR="\$HOME/worktrees/${SESSION#agent-session-}"
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

echo "Starting (or reattaching to) tmux session '${SESSION}' on ${HOST}..."
ssh "${SSH_OPTS[@]}" "$HOST" "
  set -e
  if ! command -v tmux >/dev/null 2>&1; then
    echo 'ERROR: tmux not found on remote host.' >&2
    exit 1
  fi
  mkdir -p '${WORKTREE_DIR}' 2>/dev/null || true
  if ! tmux has-session -t '${SESSION}' 2>/dev/null; then
    tmux new-session -d -s '${SESSION}' -c '${WORKTREE_DIR}' 'exec sleep 3600'
  fi
"

PID1="$(ssh "${SSH_OPTS[@]}" "$HOST" "tmux list-panes -t '${SESSION}' -F '#{pane_pid}'" | head -1)"
if [ -z "$PID1" ]; then
  echo "FAIL: could not read a pane PID for session '${SESSION}' on ${HOST}." >&2
  exit 1
fi
# The pane's direct child (the marker/harness process itself), not the shell.
CHILD_PID1="$(ssh "${SSH_OPTS[@]}" "$HOST" "pgrep -P '${PID1}' | head -1" || true)"
CHECK_PID1="${CHILD_PID1:-$PID1}"
echo "Session '${SESSION}' running with PID ${CHECK_PID1} (pre-disconnect)."

echo "Simulating client disconnect (closing this SSH connection)..."
# (The connection above already closed on command completion; tmux keeps
# the session alive server-side inside the workspace regardless.)

sleep 2

echo "Reconnecting to ${HOST}..."
if ! ssh "${SSH_OPTS[@]}" "$HOST" "tmux has-session -t '${SESSION}'" 2>/dev/null; then
  echo "FAIL: tmux session '${SESSION}' no longer exists after reconnect." >&2
  exit 1
fi

PID2="$(ssh "${SSH_OPTS[@]}" "$HOST" "tmux list-panes -t '${SESSION}' -F '#{pane_pid}'" | head -1)"
CHILD_PID2="$(ssh "${SSH_OPTS[@]}" "$HOST" "pgrep -P '${PID2}' | head -1" || true)"
CHECK_PID2="${CHILD_PID2:-$PID2}"

if [ "$CHECK_PID1" != "$CHECK_PID2" ]; then
  echo "FAIL: PID changed across disconnect/reconnect (${CHECK_PID1} -> ${CHECK_PID2})." >&2
  exit 1
fi

echo "PASS: tmux session '${SESSION}' kept PID ${CHECK_PID2} running across disconnect/reconnect."
echo "(Reattach interactively with: ssh ${HOST} -t \"tmux attach -t ${SESSION}\")"
