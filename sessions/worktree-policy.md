# Worktree Policy (Milestone M5)

## Rule: 1 agent session = 1 worktree

Every parallel Agent Host session gets its own `git worktree`, checked out
from a branch dedicated to that session:

```text
Coder workspace
│
├── ~/project                        (main checkout, branch: main)
│
├── ~/worktrees/session-001          (agent/session-001)
│     └── Agent Host session A
│
├── ~/worktrees/session-002          (agent/session-002)
│     └── Agent Host session B
│
└── ~/worktrees/session-003          (agent/session-003)
      └── Agent Host session C
```

No two sessions share a working directory. This is what prevents two
parallel agents from silently overwriting each other's uncommitted edits to
the same file.

## What a Git worktree is — and is not

A Git worktree is a **code isolation boundary, not a security sandbox**.
It guarantees:

- each session gets its own working directory and index, so uncommitted
  edits in one worktree are invisible to (and cannot be clobbered by)
  another worktree
- each session works on its own branch, so commits don't collide

It does **not** guarantee:

- filesystem/process isolation between sessions (all worktrees run inside
  the same container, under the same OS user, sharing `.git/` internals)
- protection against a session with malicious or buggy tool calls
  affecting another session's files, network, or credentials

Do not conflate this with VS Code's own "Isolation: Worktree" session mode
(see `docs/POC.md` step 8 in
[`ahp-sandbox`](https://github.com/tbrandenburg/ahp-sandbox)). That is a
VS Code *client-side* setting that locks a session to Bypass-Approvals-only
permission handling. This document's worktree policy is plain `git
worktree` plumbing, managed by `scripts/create-agent-worktree.sh` /
`scripts/cleanup-agent-worktree.sh`, independent of whichever VS Code
session-isolation setting is picked for a given session. If a future
milestone (M9, M15) opts into VS Code's native Worktree isolation instead
of, or alongside, this policy, that choice — and its Bypass-Approvals
implication — must be documented explicitly here rather than assumed to
carry over.

## Lifecycle

1. **Create**: `scripts/create-agent-worktree.sh <coder-ssh-host> <session-name> [base-branch]`
   - Creates `~/worktrees/<session-name>` from `~/project`, on a new branch
     `agent/<session-name>` (defaults to branching from the main checkout's
     current branch).
   - Idempotent: re-running with the same `session-name` reuses the
     existing worktree.
2. **Work**: point the Agent Host / VS Code Remote Agent Session at
   `~/worktrees/<session-name>` (not `~/project`) for that session.
3. **Clean up**: `scripts/cleanup-agent-worktree.sh <coder-ssh-host> <session-name>`
   - Removes the worktree directory and (unless `--keep-branch` is passed)
     deletes the session's local branch.
   - Never mutates the main checkout at `~/project` beyond
     `git worktree remove`/`git branch -D`, which only ever touch the
     worktree's own directory/branch.
   - Idempotent: a no-op if the worktree is already gone.

## Memory vs. worktrees

Worktrees are a **code isolation** mechanism. They are independent of
**agent memory** (session state, session history, user memory, repository
memory), which lives under the persistent Coder home volume established in
M4 (`~/.vscode`, `~/.vscode-server`) and is shared across all worktrees of
a workspace, since memory is repository- and user-scoped, not
worktree-scoped. See `docs/milestone-reports/M5-sessions.md` for the E2E
proof that repository memory survives ending and starting a new session.
