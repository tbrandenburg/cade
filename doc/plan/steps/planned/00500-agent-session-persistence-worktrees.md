> Mandatory: read the overall plan in full before proceeding: doc/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## M5 — Agent Session Persistence & Worktrees

### Objective

Session persistence and memory are different concepts from the AHP transport proven in M4. This milestone covers **agent memory** (what the agent remembers across conversations) and **code isolation** (how multiple parallel agent sessions avoid clobbering each other's working tree).

Layer 2 becomes:

```text
Durable Session & Memory Plane
AHP
Agent Host
session state / session history
repository memory / user memory
```

Do not put memory into Temporal — that's a different concern (durable orchestration, M8). Both user and repository memory live under the same persistent Coder home volume established in M4.

### Worktree Isolation for Parallel Sessions

Parallel agent sessions should not all mutate the same checkout. A Git worktree is a **code isolation boundary, not a security sandbox**. Structure:

```text
Coder workspace
│
├── repo main checkout
│
├── worktree/session-001 → Agent Host session A
├── worktree/session-002 → Agent Host session B
└── worktree/session-003 → Agent Host session C
```

Simple rule for the first implementation: **1 agent session = 1 worktree**. Add `scripts/create-agent-worktree.sh` and `scripts/cleanup-agent-worktree.sh`. Document the policy in `sessions/worktree-policy.md`.

**Do not conflate this with VS Code's own "Isolation: Worktree" session mode.** This milestone's worktree policy is plain `git worktree` plumbing, independent of whichever VS Code session-isolation setting is picked. The two are easy to confuse because they share the word "worktree": per the [`ahp-sandbox`](https://github.com/tbrandenburg/ahp-sandbox) POC (`docs/POC.md` step 8), VS Code's own Folder-isolation sessions let you choose an approval/permission level (Default vs Bypass Approvals), while its Worktree-isolation sessions are locked to Bypass Approvals only. If M9 or M15 ever pick VS Code's native Worktree isolation instead of (or alongside) M5's `git worktree` scripts, document that choice explicitly and note the Bypass-Approvals implication in `sessions/worktree-policy.md` rather than assuming Folder-isolation's approval prompts still apply.

### Validation Milestone M5

1. Start two agent sessions.
2. Have each modify the same file differently.
3. Confirm they're operating in separate worktrees.
4. Confirm neither silently overwrites the other's working tree.

### Manual E2E Test M5

1. Create two agent worktrees via `scripts/create-agent-worktree.sh`.
2. Start an agent session in each.
3. Ask each session to edit the same file (e.g. append a different comment to the same line range).
4. Confirm both edits exist independently in their own worktree with no cross-contamination.
5. Clean up both worktrees via `scripts/cleanup-agent-worktree.sh` and confirm the main checkout is unaffected.
6. Confirm repository memory persists: end a session, start a new one, and confirm the agent recalls prior repository-level notes without you re-explaining them.

Record in `docs/milestone-reports/M5-sessions.md`.

