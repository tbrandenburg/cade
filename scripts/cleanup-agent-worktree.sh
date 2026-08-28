#!/usr/bin/env bash
# cleanup-agent-worktree.sh — Tear down an agent session's Git worktree
# (Milestone M5).
#
# Companion to scripts/create-agent-worktree.sh. Removes the worktree
# directory and, unless --keep-branch is passed, deletes the session's
# local branch too. Never touches the main checkout at ~/project other than
# through `git worktree remove`/`git branch -d`, which only ever operate on
# the worktree's own directory/branch.
#
# Usage: scripts/cleanup-agent-worktree.sh <coder-ssh-host> <session-name> [--keep-branch] [--force]
#   e.g. scripts/cleanup-agent-worktree.sh coder.my-workspace session-001
#
# --force        forwarded to `git worktree remove` (discards uncommitted
#                 changes in the worktree instead of failing).
# --keep-branch   do not delete the session's local branch after removing
#                 the worktree.
#
# Idempotent: if the worktree no longer exists, this is a no-op success.
#
# Exit code: 0 on success (worktree gone at the end), 1 otherwise.

set -euo pipefail

HOST="${1:-}"
SESSION="${2:-}"
shift 2 2>/dev/null || true

FORCE=""
KEEP_BRANCH=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE="1" ;;
    --keep-branch) KEEP_BRANCH="1" ;;
    *)
      echo "ERROR: unknown option '$arg'." >&2
      exit 1
      ;;
  esac
done

if [ -z "$HOST" ] || [ -z "$SESSION" ]; then
  echo "Usage: $0 <coder-ssh-host> <session-name> [--keep-branch] [--force]" >&2
  exit 1
fi

if ! [[ "$SESSION" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: session-name '$SESSION' must match [a-zA-Z0-9._-]+." >&2
  exit 1
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

REMOTE_SCRIPT="$(cat <<EOF
set -euo pipefail

PROJECT_DIR="\${HOME}/project"
WORKTREE_DIR="\${HOME}/worktrees/${SESSION}"
BRANCH="agent/${SESSION}"

if [ ! -d "\${PROJECT_DIR}/.git" ]; then
  echo "ERROR: no repository checkout found at \${PROJECT_DIR}." >&2
  exit 1
fi

cd "\${PROJECT_DIR}"

if [ ! -d "\${WORKTREE_DIR}" ]; then
  echo "No worktree for session '${SESSION}' found at \${WORKTREE_DIR}; nothing to clean up."
else
  git worktree remove ${FORCE:+--force} "\${WORKTREE_DIR}"
  echo "Removed worktree \${WORKTREE_DIR}."
fi

git worktree prune

if [ -z "${KEEP_BRANCH}" ] && git show-ref --verify --quiet "refs/heads/\${BRANCH}"; then
  git branch -D "\${BRANCH}"
fi

echo "Main checkout at \${PROJECT_DIR} unaffected:"
git -C "\${PROJECT_DIR}" status --short --branch | head -1
EOF
)"

echo "Cleaning up agent worktree '$SESSION' on $HOST..."
ssh "${SSH_OPTS[@]}" "$HOST" "$REMOTE_SCRIPT"
