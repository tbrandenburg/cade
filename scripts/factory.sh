#!/bin/sh
# ══════════════════════════════════════════════════════════════════════════════
# factory.sh — OpenCode agent orchestrator for plan-driven development
#
# Drives the full plan lifecycle:
#   1. Split  — breaks a Markdown implementation plan into per-step files under
#               doc/plan/steps/planned/.
#   2. Implement — runs an implement agent on each step in lexicographic order,
#                  moving files planned/ → in-progress/ → in-review/ → closed/.
#   3. Review   — runs a review agent after each implement pass; review-raised
#                 gap files are queued back into planned/ for automatic pick-up.
#   4. Demo     — after all steps are closed, runs a demo/handover agent that
#                 writes doc/plan/demo/HANDOVER.md.
#
# Usage:
#   factory.sh [--resume] [--dry-run] [--model <model>] <plan.md>
#
#   --resume        Skip the split step; use existing files in planned/.
#   --dry-run       Simulate the full flow without running real agents.
#   --model <name>  Pass a model identifier to opencode run --model.
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# Pretty-print helpers (tput with graceful fallback for non-TTY)
# ══════════════════════════════════════════════════════════════════════════════

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  C_RESET=$(tput sgr0)
  C_BOLD=$(tput bold)
  C_DIM=$(tput dim 2>/dev/null || printf '')
  C_CYAN=$(tput setaf 6)
  C_GREEN=$(tput setaf 2)
  C_YELLOW=$(tput setaf 3)
  C_RED=$(tput setaf 1)
  C_MAGENTA=$(tput setaf 5)
  C_BLUE=$(tput setaf 4)
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_CYAN=''; C_GREEN=''
  C_YELLOW=''; C_RED=''; C_MAGENTA=''; C_BLUE=''
fi

# log_section  "Title"          — bold cyan banner with a separator line
# log_info     "msg"            — dim white
# log_step     "msg"            — blue arrow
# log_agent    "msg"            — magenta robot
# log_ok       "msg"            — green checkmark
# log_warn     "msg"            — yellow warning
# log_error    "msg"            — red cross (to stderr)
# log_dry      "msg"            — yellow [dry-run] tag

log_section() { printf '\n%s%s┌─ %s %s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"; }
log_info()    { printf '  %s%s%s\n'              "$C_DIM"     "$1" "$C_RESET"; }
log_step()    { printf '  %s→  %s%s\n'           "$C_BLUE"    "$1" "$C_RESET"; }
log_agent()   { printf '  %s⚙  %s%s\n'           "$C_MAGENTA" "$1" "$C_RESET"; }
log_ok()      { printf '  %s✓  %s%s\n'           "$C_GREEN"   "$1" "$C_RESET"; }
log_warn()    { printf '  %s⚠  %s%s\n'           "$C_YELLOW"  "$1" "$C_RESET"; }
log_error()   { printf '%s✗  %s%s\n'             "$C_RED"     "$1" "$C_RESET" >&2; }
log_dry()     { printf '  %s[dry-run]%s %s\n'    "$C_YELLOW"  "$C_RESET" "$1"; }


prompt_split_plan() {
  PLAN_FILE="$1"
  cat <<EOF
Implementation plan file: $PLAN_FILE

Instructions:
1. Read the entire implementation plan file at the path above before doing anything else.
2. Detect the organizational unit used in the plan. It could be "Step", "Phase", "Stage", "Task", "Part", or any other top-level heading pattern that repeats (e.g. "## Step 1", "## Phase 2 —", "### Stage 3:"). Use whatever pattern the file actually uses — do not assume "Step".
3. Determine the immediate enclosing chapter heading of the unit sections (e.g. "# Implementation"), if any — the nearest ancestor heading that is not itself a unit.
4. For each such section (unit 1, unit 2, …):
   a. Derive a slug from the section heading (excluding the leading unit keyword and number) in lowercase with hyphens, e.g. for "## Step 1 — Verify SDL2" the slug is "verify-sdl2".
   b. Number the sections starting at 00100, incrementing by 100 (00100, 00200, 00300, …), zero-padded to 5 digits: e.g. "00100-verify-sdl2.md", "00200-cmake-simulator-build-target.md".
   c. Create the output directory doc/plan/steps/planned/ if it does not already exist.
   d. Create the file doc/plan/steps/planned/<padded-index>-<slug>.md. Do NOT embed the preamble or appendix. The file content must be, word-for-word:
      - First: a Markdown line "> Mandatory: read the overall plan in full before proceeding: $PLAN_FILE" followed by a blank line.
      - Then: the enclosing chapter heading line (e.g. "# Implementation") copied verbatim, if one exists, followed by a blank line.
      - Then: the full text of that section copied verbatim, including its heading, goal, all sub-sections, all code blocks, and all tables.
   e. Do NOT paraphrase, summarise, or omit any text from the section itself — copy every character exactly as it appears in the source file.
5. If AGENTS.md does not already exist in the repository root, create it with: a PRD-level product
   description derived from the plan, max 200 lines, with these sections — Purpose, Goals,
   Non-Goals, Constraints, Architecture Decisions, Design Principles, Main Features, Main Use Cases
6. After writing all files, print a summary listing each file created and its byte size.
EOF
}

prompt_implement_step() {
  STEP_FILE="$1"
  IN_PROGRESS="$2"
  cat <<EOF
Current step file: $IN_PROGRESS

Instructions:
1. Read the step file at the path above before doing anything else. It links to the overall implementation plan file — reading that linked plan is mandatory for shared context (goals, constraints, architecture, references) before implementing. The step file itself is the sole source of truth for the actionable scope of this run.
2. Check whether the step was already (partially) implemented by inspecting the files and changes it describes.
   - If a file already exists with the correct content, do not recreate it.
   - If a file exists but is incorrect or incomplete, update only what is wrong.
   - If nothing exists yet, implement from scratch.
3. Implement every action that is not yet done exactly as described — create missing files and apply missing edits.
4. Context intelligence: unless the step or plan already pins exact library versions, APIs, or
   config to use, do web and/or context7 research on external libraries/frameworks touched by
   this step to confirm current, correct usage before writing code.
5. Run ALL validation and E2E checks listed in the step, without exception.
   - Do not skip, defer, or summarise any check.
   - If a check fails, print the exact error output, fix the root cause, and re-run the check until it passes.
   - Do not mark the step done if any check still fails after correction attempts.
6. Follow the coding conventions described in the step and any conventions file present in the repo root (e.g. AGENTS.md, CONTRIBUTING.md, or similar).
7. Do NOT create, modify, or delete any file outside the scope described in the step.
8. IMMUTABILITY RULE: Never modify or delete any file under doc/plan/steps/ regardless of its
   state (planned, in-progress, in-review, closed). Plan files are append-only records — only
   the factory.sh orchestrator may move them.
   Exception: Following steps are allowed to be surgically edited when a
   lesson learned is mission-critical to prevent a mistake in an upcoming step.
9. After ALL actions and ALL validation and E2E checks pass, print "IMPLEMENTATION DONE: $STEP_FILE".
10. Lessons learned: if during this step you encountered a non-obvious pitfall, a surprising
    behaviour, or a constraint that future implementers must know to avoid repeating the same
    mistake, update AGENTS.md surgically — append only a concise bullet under the most
    relevant existing section (e.g. "Key Pitfalls"). Do NOT rewrite, reformat, or restructure
    any other part of AGENTS.md.
11. If you reach a point where you cannot continue without human input (missing credentials,
   hardware required, ambiguous requirements, unresolvable conflict, etc.) do NOT guess.
   Instead print exactly this line (no leading spaces) followed by a plain-text explanation
   of what is needed:
<implement-status>blocked</implement-status>
   Then stop.
EOF
}

prompt_review_step() {
  STEP_FILE="$1"
  IN_REVIEW="$2"
  cat <<EOF
closed step file: $IN_REVIEW
Planned directory:   doc/plan/steps/planned/

Instructions:
1. Read the closed step file at the path above.
2. IMMUTABILITY RULE: You must NEVER modify or delete any existing file under doc/plan/steps/
   regardless of its state. Plan files are immutable records. The only permitted write
   operation is creating new gap-fill files in doc/plan/steps/planned/. Violating this rule
   corrupts the audit trail.
   Exception: Following steps are allowed to be surgically edited when a
   lesson learned is mission-critical to prevent a mistake in an upcoming step.
3. Inspect the actual files on disk that the step was supposed to create or modify.
4. Re-run every validation and E2E check listed in the step independently — do not trust the implementer's output.
   - Run each check yourself and capture the actual output.
   - A check passes only if the check exits 0 and produces the expected output.
   - A check failure is a gap, even if the files look correct.
5. Check whether every action in the step was fully and correctly implemented.
6. Apply the Boy Scout Rule — scoped strictly to the files this step created or modified.
   Do not audit the wider codebase. While reading those touched files AND while executing
   every validation and E2E check, look for anything within that scope that should be addressed
   before it silently poisons later steps. Signal sources:
   - Side-findings: bugs or misconfigurations introduced or exposed by this step's changes.
   - Hickup-prevention: anything left fragile or racy in the touched code that will likely break a future step.
   - Technical debt: TODOs, dead code, inconsistent naming, or copy-paste left behind by this step.
   - "Fishy" things: anything in the touched files that looks off — flag it so a human can decide.
   - Validation noise: compiler warnings, deprecation notices, or unexpected output produced by
     this step's changes that is not a hard failure today but signals a future problem.
   Stay focused: if a problem is not traceable to what this step touched, leave it alone.
7. Gap-step procedure (apply to both missing implementation items AND Boy Scout findings):
   a. List all files already present in doc/plan/steps/planned/ to find the highest gap suffix already used for this step's base number.
   b. Before creating any gap file, scan the full filenames and contents of all files in
      doc/plan/steps/planned/ for a step that already covers the same topic. If a sufficiently
      similar gap already exists, skip creating a duplicate and note "DUPLICATE SKIPPED: <existing-file> already covers this".
   c. Derive the next available gap number: take the base number of the current step and increment the suffix (e.g. current step 00100-…, existing gaps 00101, next is 00102).
   d. Create the gap-fill step file at doc/plan/steps/planned/<gap-number>-<gap-slug>.md.
      The file must contain: a brief preamble describing the gap (including WHY it matters), then the specific actions needed to fix it.
   e. Print "GAP CREATED: <gap-number>-<gap-slug>.md — <one-line reason>" for each gap file created.
8. Lessons learned: if during this review you identified a non-obvious pitfall, a surprising
   behaviour, or a constraint that future implementers must know to avoid repeating the same
   mistake, update AGENTS.md surgically — append only a concise bullet under the most
   relevant existing section (e.g. "Key Pitfalls"). Do NOT rewrite, reformat, or restructure
   any other part of AGENTS.md.
9. After all checks, print exactly one of the following status lines (no leading spaces),
   then stop:
   - If the step is complete, all validation and E2E checks pass, AND no gaps were raised:
<review-status>clean</review-status>
   - In all other cases (gaps raised, validation noise, fishy findings, or anything less than perfect):
<review-status>dirty</review-status>
   Print all GAP CREATED lines before the status line.
EOF
}

prompt_demo_agent() {
  CLOSED_DIR="$1"
  cat <<EOF
Closed steps directory: $CLOSED_DIR

Instructions:
1. Read every file in $CLOSED_DIR to understand what was implemented across all steps.
2. Perform an end-to-end run without any mocking, stubbing, or skipping
   to confirm the full system works. Capture the output.
3. Take screenshots or record terminal output as evidence of a working system.
   Save each artefact to doc/plan/demo/<topic>/ with a descriptive name (e.g. 01-sdl2-window.png,
   02-build-success.txt).
4. Write a customer-facing handover document at doc/plan/demo/<topic>/HANDOVER.md containing:
   a. Executive summary: what was built and why.
   b. What works: a plain-language list of delivered features with evidence (link the
      artefacts from step 3).
   c. How to build and run: a minimal numbered quick-start the customer can follow
      verbatim to reproduce the result on their machine.
   d. How to test: a short list of manual test cases (action → expected result) covering
      the most important user-visible behaviours.
   e. Known limitations: anything not yet done or known to be fragile.
4. Archive closed step files: Move all files from doc/plan/steps/closed/ to doc/plan/steps/archived/<topic>/ to keep a record of the implementation history without cluttering the workspace.
5. Archive plan file: Move doc/plan/plan.md to doc/plan/steps/archived/<topic>/plan.md to keep a record of the original plan without cluttering the workspace.
6. Print "DEMO READY: doc/plan/demo/<topic>/HANDOVER.md" when done.
EOF
}

prompt_plan_feature() {
  GOAL="$1"
  cat <<'PROMPT_EOF'
You are an experienced software architect.

Your task is to explore the current codebase and produce a detailed, actionable
implementation plan for the goal described at the end of this prompt.

Instructions:
1. Explore the codebase first: read relevant files, existing architecture, recent
   commits, build system, and any existing abstractions related to the goal.
2. Produce a plan with EXACTLY these sections (use these exact headings):

   ## Architecture Assessment
   A short analysis of the existing code structure relevant to the goal.

   ## Structural Constraints
   A table of concrete technical constraints discovered during analysis that every
   step must respect. Format: | Constraint | Where | Implication |
   Examples: incompatible headers, non-editable generated files, reference members
   requiring complete types, libraries only available in certain build targets, etc.
   This section is the single authoritative list of "things that will bite you" —
   implementers must read it before touching any file.

   ## Approaches
   2-3 possible approaches ranked simplest to most complete, each with trade-offs.

   ## Recommended Approach
   Which approach and why.

   ## Summary of Files
   A table: File | Action | Notes

   ## Known Risks and Mitigations
   A table of anticipated compile/link/runtime gaps and their fixes.
   Format: | Symbol or problem likely missing | Root cause | Fix |
   Treat every anticipated undefined symbol, missing include, or runtime
   failure as a row here — this prevents implementers from being surprised
   and wasting time diagnosing known issues.

   ## Out of scope - Do Not Overbuild
   Explicit list of things to avoid or defer.

   ## Implementation Plan
   Step-by-step plan. Each step MUST follow this format exactly:

   ## Step N — <short-slug>

   ### Objective
   One sentence about the objective of this step and how it contributes to the overall goal.

   ## Acceptance criteria
   A bullet list of conditions that must be true for the step to be considered done.

   ### Actions
   Numbered list of concrete file changes.

   ### Validation gate
   Shell commands that must pass before the step is considered done.

   ### E2E check
   End-to-end command or manual test confirming the step works in context.

   ## Step N+1 — <short-slug-of-the-final-polishing-step>

   Use the same format like for the other steps, but this one should be the
   final polishing step that ensures the product is demo-ready.
   It should be the last step in the plan and cover any final clean-up,
   refactoring, documentation, or non-critical features that are not strictly
   required for a working demo but needed for a polished handover.

   This is the customer acceptance step - everything has to be executable and
   presentable by the end of this step.

3. Write the complete plan to doc/plan/plan.md (create the directory if needed).
4. If AGENTS.md does not already exist in the repository root, create/extend it with: a PRD-level
   product description derived from the plan, max 200 lines, with these sections — Purpose,
   Goals, Non-Goals, Constraints, Architecture Decisions, Design Principles, Main Features,
   Main Use Cases — ending with an empty "## Key Pitfalls" heading for later append-only
   lessons learned. If it already exists, leave it untouched.
5. After writing the file, print exactly: PLAN WRITTEN: doc/plan/plan.md

Goal:
PROMPT_EOF
  printf '%s\n' "$GOAL"
}


# Usage: factory.sh [--resume] [--dry-run] [--model <model>] [<path-to-implementation-plan.md>]
#   --resume        Skip Step 1 (splitting) and go straight to Step 2 (implementation).
#                   Use when doc/plan/steps/planned/ is already populated.
#   --dry-run       Simulate the full flow without running agents or modifying real files.
#                   Creates dummy step files, walks the loop, then cleans up.
#   --model <model> Model identifier passed to opencode run --model.
#                   If omitted, opencode uses its own default.

RESUME=0
DRY_RUN=0
PLAN_FILE=""
MODEL=""
PLAN_GOAL=""
FROM_PLAN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --resume)        RESUME=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --model)         MODEL="$2"; shift 2 ;;
    --from-scratch)  PLAN_GOAL="$2"; shift 2 ;;
    --from-plan)     FROM_PLAN="$2"; shift 2 ;;
    --)              shift; break ;;
    -*)              log_error "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$PLAN_GOAL" ] && [ -z "$FROM_PLAN" ] && [ "$RESUME" = "0" ] && [ "$DRY_RUN" = "0" ]; then
  log_error "Usage: $0 --from-scratch \"<prompt>\" | --from-plan <plan.md> | --resume | --dry-run [--model <name>]"
  exit 1
fi

if [ -n "$PLAN_GOAL" ] && [ -n "$FROM_PLAN" ]; then
  log_error "--from-scratch and --from-plan are mutually exclusive."
  exit 1
fi

if [ -n "$FROM_PLAN" ] && [ ! -f "$FROM_PLAN" ]; then
  log_error "File not found: $FROM_PLAN"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# Dry-run helpers
# ──────────────────────────────────────────────────────────────────────────────

# All dummy files used in dry-run mode — covers every state directory.
# planned/ entries are moved by the loop; closed/ entries ensure cleanup
# removes them wherever they land. in-progress/ and in-review/ dirs are
# created by dry_run_setup so the mv calls never fail.
DRY_RUN_FILES="
doc/plan/steps/planned/00100-dummy-step-one.md
doc/plan/steps/planned/00200-dummy-step-two.md
doc/plan/steps/planned/00300-dummy-step-three.md
doc/plan/steps/closed/00100-dummy-step-one.md
doc/plan/steps/closed/00200-dummy-step-two.md
doc/plan/steps/closed/00300-dummy-step-three.md
"

dry_run_setup() {
  for f in $DRY_RUN_FILES; do
    mkdir -p "$(dirname "$f")"
    printf '# dry-run\n' > "$f"
  done
  mkdir -p doc/plan/steps/in-progress
  mkdir -p doc/plan/steps/in-review
  log_dry "Dummy files created."
}

dry_run_cleanup() {
  for f in $DRY_RUN_FILES; do
    rm -f "$f"
  done
  log_dry "Cleanup done."
}

# Detects whether an opencode run aborted mid-conversation instead of
# completing normally. opencode occasionally crashes out with things like:
#   "Error: Bad Request: This model does not support assistant message prefill."
#   "Error: The user rejected permission to use this specific tool call."
# leaving the step stuck. We don't try to pattern-match the error text —
# any non-zero exit status is treated as a broken run. $1 = exit status.
agent_run_is_broken() {
  [ "$1" -ne 0 ]
}

# In dry-run mode: print what would be called instead of calling it.
# Otherwise: run opencode, capturing output and exit status. If opencode
# aborts mid-run (see agent_run_is_broken), nudge it back to life a few
# times with `opencode run -c` (continue the previous session) fed the
# literal input "Continue" before giving up. If it never recovers, the
# output is tagged with <agent-run-status>failed</agent-run-status> so
# callers can detect the failure instead of blindly treating the step as done.
run_agent() {
  agent_label="$1"
  agent_prompt="$2"

  if [ "$DRY_RUN" = "1" ]; then
    if [ -n "$MODEL" ]; then
      log_dry "Would run: opencode run --model \"$MODEL\" <$agent_label>"
    else
      log_dry "Would run: opencode run <$agent_label>"
    fi
    return 0
  fi

  agent_max_retries=5
  agent_attempt=0

  if [ -n "$MODEL" ]; then
    agent_output="$(opencode run --model "$MODEL" "$agent_prompt" 2>&1)"
  else
    agent_output="$(opencode run "$agent_prompt" 2>&1)"
  fi
  agent_status=$?

  while agent_run_is_broken "$agent_status" && [ "$agent_attempt" -lt "$agent_max_retries" ]; do
    agent_attempt=$((agent_attempt + 1))
    log_warn "opencode aborted mid-run (attempt $agent_attempt/$agent_max_retries) — nudging with 'opencode run -c \"Continue if work is left\"'..." >&2
    agent_output="$(printf 'Continue if work is left\n' | opencode run -c 2>&1)"
    agent_status=$?
  done

  if agent_run_is_broken "$agent_status"; then
    log_error "opencode <$agent_label> still failing after $agent_max_retries nudges." >&2
    printf '%s\n' "$agent_output"
    printf '<agent-run-status>failed</agent-run-status>\n'
  else
    printf '%s\n' "$agent_output"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Step 0 — Generate implementation plan (only when --from-scratch is used)
# ──────────────────────────────────────────────────────────────────────────────

if [ -n "$PLAN_GOAL" ]; then
  log_section "Step 0 — Generate implementation plan"
  log_info "Goal: $PLAN_GOAL"
  mkdir -p doc/plan
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "Would run: opencode run <prompt_plan_feature>"
    printf '# dry-run plan\n\n## Step 1 — dummy\n\n**Goal:** dry-run placeholder.\n\n### Actions\n1. Nothing.\n\n### Validation gate\n```bash\ntrue\n```\n\n### E2E check\ntrue\n' > doc/plan/plan.md
  else
    log_agent "Running planner agent..."
    run_agent "prompt_plan_feature" "$(prompt_plan_feature "$PLAN_GOAL")"
  fi
  PLAN_FILE="doc/plan/plan.md"
  if [ ! -f "$PLAN_FILE" ]; then
    log_error "Planner agent did not produce doc/plan/plan.md"
    exit 1
  fi
  log_ok "Plan written: $PLAN_FILE"
fi

if [ -n "$FROM_PLAN" ]; then
  mkdir -p doc/plan
  cp "$FROM_PLAN" doc/plan/plan.md
  PLAN_FILE="doc/plan/plan.md"
  log_ok "Plan copied to: $PLAN_FILE"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 1 - Creating digestable implementation steps
# ──────────────────────────────────────────────────────────────────────────────

if [ "$RESUME" = "0" ]; then
  if [ -d "doc/plan/steps/planned" ] && [ -n "$(ls -A doc/plan/steps/planned 2>/dev/null)" ]; then
    log_error "doc/plan/steps/planned is not empty. Remove or clear it before running, or use --resume."
    exit 1
  fi

  log_section "Step 1 — Split plan into steps"
  log_info "Plan: ${PLAN_FILE:-'(dry-run dummy)'}"

  if [ "$DRY_RUN" = "1" ]; then
    dry_run_setup
    log_dry "Would run: opencode run <prompt_split_plan>"
  else
    log_agent "Running split agent..."
    run_agent "prompt_split_plan" "$(prompt_split_plan "$PLAN_FILE")"
  fi
else
  log_info "--resume: skipping split, using existing files in doc/plan/steps/planned/"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 2 - Implement each planned step in order, with review and gap-filling
# ──────────────────────────────────────────────────────────────────────────────

# Precondition: planned directory must exist and contain at least one file
if [ ! -d "doc/plan/steps/planned" ] || [ -z "$(ls -A doc/plan/steps/planned 2>/dev/null)" ]; then
  log_error "doc/plan/steps/planned is empty or missing. Run Step 1 first."
  exit 1
fi

mkdir -p doc/plan/steps/in-progress
mkdir -p doc/plan/steps/in-review
mkdir -p doc/plan/steps/closed

# The loop re-reads the planned directory on every iteration so that newly
# injected gap-fill files (e.g. 00101-…, 00102-…) are picked up automatically.
while true; do
  # Pick the lexicographically first remaining planned file
  STEP_FILE="$(ls doc/plan/steps/planned/ 2>/dev/null | sort | head -1)"

  if [ -z "$STEP_FILE" ]; then
    log_ok "All steps processed."
    break
  fi

  PLANNED="doc/plan/steps/planned/$STEP_FILE"
  IN_PROGRESS="doc/plan/steps/in-progress/$STEP_FILE"
  IN_REVIEW="doc/plan/steps/in-review/$STEP_FILE"

  log_section "Implementing: $STEP_FILE"

  # 2a. Move to in-progress
  log_step "planned → in-progress"
  mv "$PLANNED" "$IN_PROGRESS"

  # 2b. Implement
  log_agent "Running implement agent..."
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "Would run: opencode run <prompt_implement_step>"
    IMPLEMENT_OUTPUT="IMPLEMENTATION DONE: $STEP_FILE"
  else
    IMPLEMENT_OUTPUT="$(run_agent "prompt_implement_step" "$(prompt_implement_step "$STEP_FILE" "$IN_PROGRESS")")"
  fi

  # Emergency exit: opencode itself crashed mid-run and could not be revived
  if echo "$IMPLEMENT_OUTPUT" | grep -qF '<agent-run-status>failed</agent-run-status>'; then
    log_error "opencode crashed while implementing: $STEP_FILE"
    printf '\n%s%sWhat to do:%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '  1. Inspect the error above (the session may be recoverable with:\n'
    printf '     echo "Continue" | opencode run -c).\n'
    printf '  2. The step file is still at: %s\n' "$IN_PROGRESS"
    printf '     Move it back to planned/ when ready:\n'
    printf '     mv %s doc/plan/steps/planned/%s\n' "$IN_PROGRESS" "$STEP_FILE"
    printf '  3. Re-run: %s --resume %s\n\n' "$0" "${PLAN_FILE:-''}"
    exit 2
  fi

  # Emergency exit: agent signalled it is blocked and needs human input
  if echo "$IMPLEMENT_OUTPUT" | grep -qF '<implement-status>blocked</implement-status>'; then
    log_error "Agent blocked on: $STEP_FILE"
    # Extract and print whatever the agent wrote after the tag as instructions
    BLOCKED_MSG="$(echo "$IMPLEMENT_OUTPUT" | sed -n '/<implement-status>blocked<\/implement-status>/,$ p' | tail -n +2)"
    if [ -n "$BLOCKED_MSG" ]; then
      printf '\n%s%sAgent message:%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
      printf '%s\n' "$BLOCKED_MSG"
    fi
    printf '\n%s%sWhat to do:%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '  1. Resolve the issue described above.\n'
    printf '  2. The step file is still at: %s\n' "$IN_PROGRESS"
    printf '     Move it back to planned/ when ready:\n'
    printf '     mv %s doc/plan/steps/planned/%s\n' "$IN_PROGRESS" "$STEP_FILE"
    printf '  3. Re-run: %s --resume %s\n\n' "$0" "${PLAN_FILE:-''}"
    exit 2
  fi

  # 2c. Move to in-review
  log_step "in-progress → in-review"
  mv "$IN_PROGRESS" "$IN_REVIEW"

  log_agent "Running review agent..."

  # 2d. Review and inject gap-fill steps if needed
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "Would run: opencode run <prompt_review_step>"
    REVIEW_OUTPUT="<review-status>clean</review-status>"
  else
    REVIEW_OUTPUT="$(run_agent "prompt_review_step" "$(prompt_review_step "$STEP_FILE" "$IN_REVIEW")")"
  fi

  # Emergency exit: opencode itself crashed mid-run and could not be revived
  if echo "$REVIEW_OUTPUT" | grep -qF '<agent-run-status>failed</agent-run-status>'; then
    log_error "opencode crashed while reviewing: $STEP_FILE"
    printf '\n%s%sWhat to do:%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '  1. Inspect the error above (the session may be recoverable with:\n'
    printf '     echo "Continue" | opencode run -c).\n'
    printf '  2. The step file is still at: %s\n' "$IN_REVIEW"
    printf '     Move it back to in-progress/ (or planned/) when ready and re-run.\n'
    printf '  3. Re-run: %s --resume %s\n\n' "$0" "${PLAN_FILE:-''}"
    exit 2
  fi

  # 2e. Move to closed — gaps (if any) are already queued in planned/ as new steps
  log_step "in-review → closed"
  mv "$IN_REVIEW" "doc/plan/steps/closed/$STEP_FILE"
  if echo "$REVIEW_OUTPUT" | grep -qF '<review-status>clean</review-status>'; then
    log_ok "$STEP_FILE — review clean"
  else
    log_warn "$STEP_FILE — review dirty: gap steps queued in planned/"
  fi

done

# ──────────────────────────────────────────────────────────────────────────────
# Step 3 — Demo & customer handover
# ──────────────────────────────────────────────────────────────────────────────

log_section "Step 3 — Demo & customer handover"

if [ "$DRY_RUN" = "1" ]; then
  log_dry "Would run: opencode run <prompt_demo_agent>"
else
  log_agent "Running demo agent..."
  run_agent "prompt_demo_agent" "$(prompt_demo_agent doc/plan/steps/closed)"
fi

if [ "$DRY_RUN" = "1" ]; then
  dry_run_cleanup
fi

printf '\n%s%s════════════════════════════════════════%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
printf '%s%s  ✓  Factory run complete.%s\n'                "$C_BOLD" "$C_GREEN" "$C_RESET"
printf '%s%s════════════════════════════════════════%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
