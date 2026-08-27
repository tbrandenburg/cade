# Phase 5 — Integration & Release

## Phase Objective

Get backup/restore validated, prove the entire chain end-to-end across every prior phase — including all three durability levels independently — and cut the first release.

Covers: **M14** (Backup / Restore), Final Milestone (Complete End-to-End Scenario), Final Manual E2E Test Request (incl. Durability Boundary Tests), Final Acceptance Criteria, Versioning Policy.

---

## M14 — Backup / Restore

### Objective

By this point the stack has state scattered across many services. `scripts/backup.sh` / `scripts/restore-test.sh` were created early in the plan but never actually validated with a real milestone. **A backup nobody has restored is not a backup strategy.**

### Classify State

```text
MUST BACK UP
platform repository
Coder database
Temporal database (incl. Visibility store, if on a separate backend from Persistence — confirm this stack uses Postgres for both)
OpenBao
important workspace state (persistent /home/coder, incl. agent memory/session state)

REPRODUCIBLE / DON'T NEED BACKUP
containers
Docker images you can rebuild
Dev Containers
toolchains generated from Dockerfiles
build caches (registry, sccache)
temporary agent worktrees
```

Document this classification in `backup/backup-policy.md`, including:

- **OpenBao:** back up via `bao operator raft snapshot save` (Integrated Storage/Raft), not a raw volume copy, and separately back up the unseal keys/KMS reference — a restored instance starts **sealed** and unusable without them.
- **Coder home persistence is a template property, not automatic** — verify the workspace templates pin the home volume to an immutable resource ID (`coder_workspace.me.id`) with `lifecycle { ignore_changes = all }`; a naive template can silently wipe the "persistent" volume on restart.

### Validation Milestone M14

1. Create workspace, and write a marker file with a unique, timestamped value into `/home/coder`.
2. Create Temporal workflow.
3. Store test secret (in OpenBao, per Phase 4 M12).
4. Create agent/session data (per Phase 1 M4/M5).
5. Run `make backup` (OpenBao via raft snapshot save; unseal keys backed up separately).
6. Destroy relevant containers/volumes (the "MUST BACK UP" set only).
7. Run `make restore-test` (OpenBao via raft snapshot restore, then unseal).
8. Verify state: workspace (marker file byte-for-byte identical — not just "workspace starts"), workflow, secret, and agent/session data are all recovered.

### Manual E2E Test M14

Run the 8-step sequence above against the real stack — not a dry run. Confirm each of the four "MUST BACK UP" categories independently:

1. Repository/platform config restored.
2. Coder database restored (workspace metadata intact).
3. Temporal database restored (workflow history intact, including Visibility store if separate).
4. OpenBao restored via raft snapshot restore, then successfully unsealed with the backed-up keys, test secret still retrievable.
5. Persistent workspace home restored — verified via the marker-file content check, not just "workspace starts."

Record in `backup/restore-test.md` and `docs/milestone-reports/M14-backup.md`.

---

## Final Milestone — Complete End-to-End Scenario

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

## Durability Boundary Tests

Steps A–L above prove the automation/coordination chain. These three additional tests prove the three durability levels (`docs/INITIAL.md` Section 2.2) **individually** — do not assume proving one implies the others.

### Durability Test 1 — UI failure (AHP)

```text
agent running → close VS Code → reopen → same session continues
```

Same test as Phase 1 M4's Manual E2E Test, repeated here as part of the final combined proof. AHP validates this.

### Durability Test 2 — Worker failure (Temporal)

```text
Temporal workflow running → kill worker → restart → workflow continues
```

Same test as Phase 3 M8's Manual E2E Test. Temporal validates this.

### Durability Test 3 — Workspace restart (Coder)

```text
Coder workspace → stop → start → repo + persistent home survive
```

Coder validates this — Coder explicitly separates persistent resources (the home volume) from ephemeral workspace resources (the container). Do not assume Durability Test 1 passing means Durability Test 3 automatically passes — that conflation was the central architectural gap this plan originally had.

**Template property, not automatic:** verify at the file-content level. Write a marker file with a unique, timestamped value into `/home/coder` before stopping the workspace; after starting it again, assert the same file exists with byte-for-byte identical content. This also confirms the templates correctly pin the home volume to an immutable resource ID rather than silently recreating it.

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
- [ ] VS Code Agent Host session persists across editor close/reopen (Durability Test 1).
- [ ] Parallel agent sessions operate in isolated Git worktrees without overwriting each other.
- [ ] Coder workspace autostop does not terminate an active agent session.
- [ ] Both `opencode` and `pi` are installed in the workspace and have each successfully diagnosed a seeded failure.
- [ ] Both `opencode` and `pi` run sandboxed via `srt` (Anthropic Sandbox Runtime) and VS Code's own `chat.agent.sandbox.enabled`, with verified denied file read, denied network destination, and cross-credential isolation.
- [ ] Self-hosted runner uses JIT/ephemeral registration (or a documented time-boxed risk acceptance) and a digest-pinned, minimal base image.
- [ ] Normal GitHub Actions run deterministic CI.
- [ ] `gh-aw` performs repository-centric reasoning within an explicit network firewall allowlist and minimal `permissions:` block.
- [ ] Temporal survives worker interruption (Durability Test 2), using a shared Task Queue constant, explicit Activity timeouts, and idempotent Activities.
- [ ] Coder workspace restart preserves repo and persistent home (Durability Test 3).
- [ ] Local OCI registry (auth-protected, no public port) + build cache (cache-key path issues addressed) measurably reduce fresh-workspace build time.
- [ ] MCP/internal APIs expose controlled capabilities over `stdio` or an authenticated/unix-socket transport, with reservation tokens bound to the requesting caller.
- [ ] Simulated device operations work.
- [ ] OPA can deny an unsafe action, backed by an `opa test` suite.
- [ ] OpenBao runs with TLS, revoked initial root token, and securely backed-up unseal keys.
- [ ] Secrets are not stored in source.
- [ ] Important execution events are observable via Prometheus (not exposed publicly) and a version-controlled Grafana dashboard.
- [ ] A full backup has been created and successfully restored, verified against every "MUST BACK UP" category (M14).
- [ ] End-to-end flow begins in GitHub and returns a result to GitHub.
- [ ] Interactive access does not require public exposure of the server, and uses an explicit least-privilege Tailscale ACL rather than the allow-all default.
- [ ] All milestone reports (across all five phases) are committed.

---

## Versioning Policy

`VERSION.md` tracks the platform's release version, not individual milestones or phases. Milestones and phases are implementation stages, not releases — do not tag or version-bump per phase.

- While any milestone from Phases 1–4 is incomplete, the platform is pre-release. `VERSION.md` should read `unreleased`.
- Once every checkbox above is checked and the Final Milestone end-to-end scenario (including the Durability Boundary Tests) passes, set `VERSION.md` to `0.1.0`.
- After `0.1.0`, use standard SemVer (`MAJOR.MINOR.PATCH`):
  - **MAJOR** — breaking change to the developer-facing contract (Make targets, repo layout, workspace types)
  - **MINOR** — backward-compatible capability added (new workspace type, new MCP tool, new milestone-like feature)
  - **PATCH** — bug fix, security patch, dependency bump with no behavior change
- Record every version bump as a dated entry in `VERSION.md` with a one-line summary of what changed.

---

## Phase 5 Documentation & Agent Instructions Update

Before Phase 5 is considered done, you, as the agent, must:

1. **Update project docs** — do a final pass over `docs/architecture.md`, `docs/operations.md`, `docs/security.md`, and `docs/disaster-recovery.md` so they describe the fully integrated system as it actually exists, with no remaining drift from any earlier phase. `docs/disaster-recovery.md` specifically should reflect the real M14 backup/restore procedure.
2. **Update `AGENTS.md`** at the repo root with:
   - **Guidelines** — consolidate any cross-phase rules that only became clear once everything was integrated (e.g. ordering dependencies between services on startup, timing constraints across the full chain, backup/restore gotchas).
   - **Agent Instructions** — a single "how to run the full end-to-end scenario yourself" walkthrough, referencing the Final Manual E2E Test Request and Durability Boundary Tests above.
   - **Lessons Learned** — a dated entry (`## Phase 5 — <date>`) covering what broke, what surprised you, and what to avoid next time. Append; do not overwrite prior entries. This closes out the lessons-learned log for the `0.1.0` release.
3. **Update `VERSION.md`** per the Versioning Policy above, only after all other steps in this section are complete.

---

## Phase 5 Exit Criteria

- [ ] A full backup/restore cycle (M14) has been executed and verified against all four "MUST BACK UP" categories.
- [ ] The full 8-step end-to-end scenario runs without a faked step.
- [ ] The Final Manual E2E Test Request (A–L) passes, executed by you, the agent, personally.
- [ ] All three Durability Boundary Tests (UI/AHP, Worker/Temporal, Workspace/Coder) pass independently.
- [ ] Every checkbox in Final Acceptance Criteria is checked.
- [ ] `docs/architecture.md`, `docs/operations.md`, `docs/security.md`, and `docs/disaster-recovery.md` are fully up to date with no drift from the implementation.
- [ ] `AGENTS.md` has a final consolidated Guidelines section, complete Agent Instructions, and a dated Phase 5 Lessons Learned entry.
- [ ] `VERSION.md` is bumped from `unreleased` to `0.1.0`.
