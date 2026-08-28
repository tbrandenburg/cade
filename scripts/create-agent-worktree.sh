#!/usr/bin/env bash
# create-agent-worktree.sh — Create an isolated Git worktree for one agent
# session (Milestone M5).
#
# Policy: 1 agent session = 1 worktree (see sessions/worktree-policy.md). A
# Git worktree is a code isolation boundary, not a security sandbox — do not
# treat it as one. Run this on the Coder workspace (over SSH, matching the
# M4 scripts' pattern) so multiple parallel Agent Host sessions never
# clobber the same checkout.
#
# Usage: scripts/create-agent-worktree.sh <coder-ssh-host> <session-name> [base-branch]
#   e.g. scripts/create-agent-worktree.sh coder.my-workspace session-001
#   e.g. scripts/create-agent-worktree.sh coder.my-workspace session-001 main
#
# Requires: `coder config-ssh` already run (scripts/configure-coder-ssh.sh)
# and the workspace's main checkout already cloned at ~/project (Milestone M3/M4).
#
# Idempotent: re-running with the same session-name reuses the existing
# worktree instead of failing.
#
# Exit code: 0 on success (worktree exists at the end), 1 otherwise.

set -euo pipefail

HOST="${1:-}"
SESSION="${2:-}"
BASE_BRANCH="${3:-}"

if [ -z "$HOST" ] || [ -z "$SESSION" ]; then
  echo "Usage: $0 <coder-ssh-host> <session-name> [base-branch]" >&2
  echo "Run scripts/configure-coder-ssh.sh first, then pass e.g. coder.<workspace-name> session-001." >&2
  exit 1
fi

if ! [[ "$SESSION" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: session-name '$SESSION' must match [a-zA-Z0-9._-]+ (used as a directory and branch-name suffix)." >&2
  exit 1
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

REMOTE_SCRIPT="$(cat <<EOF
set -euo pipefail

PROJECT_DIR="\${HOME}/project"
WORKTREE_ROOT="\${HOME}/worktrees"
WORKTREE_DIR="\${WORKTREE_ROOT}/${SESSION}"
BRANCH="agent/${SESSION}"

if [ ! -d "\${PROJECT_DIR}/.git" ]; then
  echo "ERROR: no repository checkout found at \${PROJECT_DIR}." >&2
  exit 1
fi

cd "\${PROJECT_DIR}"

if [ -d "\${WORKTREE_DIR}" ]; then
  echo "Worktree for session '${SESSION}' already exists at \${WORKTREE_DIR}."
  git worktree list | grep -F "\${WORKTREE_DIR}"
  exit 0
fi

mkdir -p "\${WORKTREE_ROOT}"

BASE="${BASE_BRANCH}"
if [ -z "\${BASE}" ]; then
  BASE="\$(git rev-parse --abbrev-ref HEAD)"
fi

if git show-ref --verify --quiet "refs/heads/\${BRANCH}"; then
  echo "Branch \${BRANCH} already exists; attaching worktree to it."
  git worktree add "\${WORKTREE_DIR}" "\${BRANCH}"
else
  git worktree add -b "\${BRANCH}" "\${WORKTREE_DIR}" "\${BASE}"
fi

echo "Created worktree for session '${SESSION}':"
echo "  path:   \${WORKTREE_DIR}"
echo "  branch: \${BRANCH}"
echo "  base:   \${BASE}"
EOF
)"

echo "Creating agent worktree '$SESSION' on $HOST..."
ssh "${SSH_OPTS[@]}" "$HOST" "$REMOTE_SCRIPT"
