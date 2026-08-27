# Phase 5 — Integration & Release

## Phase Objective

Prove the entire chain end-to-end, across every prior phase, and cut the first release.

Covers: Final Milestone (Complete End-to-End Scenario), Final Manual E2E Test Request, Final Acceptance Criteria, Versioning Policy.

---

## Final Milestone — Complete End-to-End Scenario

This is the most important acceptance test. Do not fake any step. Use the simulated embedded project.

### Step 1 — Create problem

Create a GitHub issue: *"Embedded simulator regression: demo ECU validation failing"*.

### Step 2 — Agent investigation

Trigger `gh-aw failure investigator` (Phase 2). Agent must inspect the issue, inspect the repository, inspect the latest CI, and reason about the failure — using the harness chosen in Phase 1 M6 (`opencode` or `pi`).

### Step 3 — Deterministic local build

Agent or workflow invokes the approved deterministic GitHub Action:

```text
GitHub → self-hosted runner → Docker → embedded build
```

### Step 4 — Start durable process

Workflow starts the Temporal validation workflow (Phase 3), orchestrating: reserve simulated device → wait → run simulated test → retrieve logs.

### Step 5 — Capability call

Temporal activity calls the Lab/Device API (Phase 3 M8). The API must go through the policy checks established in Phase 4 M9.

### Step 6 — Simulated validation

Run firmware artifact + simulated ECU. Return a structured result.

### Step 7 — Agent evaluates output

Agent reads the result and reports: failure cause, recommended fix, test evidence.

### Step 8 — GitHub receives result

Result must appear in GitHub as a workflow summary, issue comment, PR comment, or check result.

---

## Final Manual E2E Test Request (performed by you, the agent)

You, as the agent, must execute this test personally. No automated test is accepted as a substitute.

Start from a clean state:

```bash
make down
docker system prune
```

Do not delete persistent named volumes unless the test explicitly requires it.

### A. Start platform

```bash
make up
```

Verify health.

### B. Create fresh Coder workspace

`embedded-linux`. Connect VS Code.

### C. Modify sample embedded code

Create a deliberate regression. Commit and push branch.

### D. Observe GitHub CI

Normal deterministic CI should fail.

### E. Run agent investigation

Trigger `gh-aw`. Verify meaningful diagnosis.

### F. Start approved local capability

Trigger the deterministic workflow. Verify GitHub sends the job to the self-hosted private runner.

### G. Verify private execution

On the server: `docker ps`. Confirm the build/test workload actually ran locally.

### H. Verify durable orchestration

Start Temporal validation workflow. During execution: `docker compose restart temporal-worker`. Workflow must still complete.

### I. Verify tool fabric

Observe: Temporal → Lab API → simulated ECU.

### J. Verify governance

Attempt one deliberately prohibited operation. OPA must reject it.

### K. Verify observability

Find the test execution in Grafana/telemetry.

### L. Verify GitHub result

Final result must appear back in GitHub.

---

## Final Acceptance Criteria

The implementation is complete only if all of the following are true:

- [ ] Fresh clone can bootstrap the stack.
- [ ] No secret is committed.
- [ ] Docker Compose owns the platform lifecycle.
- [ ] GitHub self-hosted runner works without inbound public access.
- [ ] Coder can create a fresh Docker development workspace.
- [ ] Workspace automatically obtains repository source.
- [ ] Workspace contains a working custom build toolchain.
- [ ] VS Code can attach to the workspace.
- [ ] Both `opencode` and `pi` are installed in the workspace and have each successfully diagnosed a seeded failure.
- [ ] Normal GitHub Actions run deterministic CI.
- [ ] `gh-aw` performs repository-centric reasoning.
- [ ] Temporal survives worker interruption.
- [ ] MCP/internal APIs expose controlled capabilities.
- [ ] Simulated device operations work.
- [ ] OPA can deny an unsafe action.
- [ ] Secrets are not stored in source.
- [ ] Important execution events are observable.
- [ ] End-to-end flow begins in GitHub and returns a result to GitHub.
- [ ] Interactive access does not require public exposure of the server.
- [ ] All milestone reports (across all five phases) are committed.

---

## Versioning Policy

`VERSION.md` tracks the platform's release version, not individual milestones or phases. Milestones and phases are implementation stages, not releases — do not tag or version-bump per phase.

- While any milestone from Phases 1–4 is incomplete, the platform is pre-release. `VERSION.md` should read `unreleased`.
- Once every checkbox above is checked and the Final Milestone end-to-end scenario passes, set `VERSION.md` to `0.1.0`.
- After `0.1.0`, use standard SemVer (`MAJOR.MINOR.PATCH`):
  - **MAJOR** — breaking change to the developer-facing contract (Make targets, repo layout, workspace types)
  - **MINOR** — backward-compatible capability added (new workspace type, new MCP tool, new milestone-like feature)
  - **PATCH** — bug fix, security patch, dependency bump with no behavior change
- Record every version bump as a dated entry in `VERSION.md` with a one-line summary of what changed.

---

## Phase 5 Exit Criteria

- [ ] The full 8-step end-to-end scenario runs without a faked step.
- [ ] The Final Manual E2E Test Request (A–L) passes, executed by you, the agent, personally.
- [ ] Every checkbox in Final Acceptance Criteria is checked.
- [ ] `VERSION.md` is bumped from `unreleased` to `0.1.0`.
