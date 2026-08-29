> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 5 — Integration & Release

## M15 — Complete End-to-End Scenario

This is the most important acceptance test. Do not fake any step. Use the simulated embedded project.

### Step 1 — Create problem

Create a GitHub issue: *"Embedded simulator regression: demo ECU validation failing"*.

### Step 2 — Agent investigation

Trigger `gh-aw failure investigator` (Phase 2). Agent must inspect the issue, inspect the repository, inspect the latest CI, and reason about the failure — using the harness chosen in Phase 1 M9 (`opencode` or `pi`).

### Step 3 — Deterministic local build

Agent or workflow invokes the approved deterministic GitHub Action:

```text
GitHub → self-hosted runner → Docker → embedded build
```

### Step 4 — Start durable process

Workflow starts the Temporal validation workflow (Phase 3, M8), orchestrating: reserve simulated device → wait → run simulated test → retrieve logs.

### Step 5 — Capability call

Temporal activity calls the Lab/Device API (Phase 3, M11). The API must go through the policy checks established in Phase 4 (M12).

### Step 6 — Simulated validation

Run firmware artifact + simulated ECU. Return a structured result.

### Step 7 — Agent evaluates output

Agent reads the result and reports: failure cause, recommended fix, test evidence.

### Step 8 — GitHub receives result

Result must appear in GitHub as a workflow summary, issue comment, PR comment, or check result.
