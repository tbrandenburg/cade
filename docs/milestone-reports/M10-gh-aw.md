# M10 GitHub Agentic Workflows — Milestone Report

Evidence captured for Phase 2 / Milestone M10 (GitHub Agentic Workflows),
per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`docs/plan/plan.md` (M10 section).

- **Timestamp (UTC):** 2026-08-28T16:52Z
- **Repository visibility (re-checked per step instructions):**
  ```
  $ gh repo view --json visibility
  {"visibility":"PUBLIC"}
  ```
  Still PUBLIC (see M2 report / `docs/security.md`). Per the step's
  correction note, `gh-aw`'s public-repo integrity auto-filtering applies
  and was **not** disabled or bypassed.

## What was built

- `.github/workflows/local-capability.yml` — deterministic capability
  workflow (build + `unittest` for `examples/hello-service`, GitHub-hosted
  `ubuntu-latest`, `push`/`pull_request`/`workflow_dispatch` triggers).
  This is the "known build failure" target watched by the investigator.
- `.github/workflows/investigate-failure.md` — the `gh-aw` source workflow:
  - `on.workflow_run` scoped to `workflows: ["local-capability"]`,
    `branches: [main]`, with a top-level `if:
    github.event.workflow_run.conclusion == 'failure'` guard (gh-aw
    v0.86.2's schema does not accept a nested `conclusion:` filter under
    `workflow_run:` despite current docs showing one — see "Lessons
    learned" below).
  - `engine: { id: pi }` / `model: copilot/gpt-5.4` — the harness chosen in
    Phase 1 M9 that `gh-aw` actually supports as a native engine (`opencode`
    is not one of `gh-aw`'s supported engines: Copilot, Claude Code, Codex,
    Gemini, Pi).
  - `permissions: { contents: read, actions: read, copilot-requests: write }`
    — no write permissions on the agent job.
  - `tools.github: { mode: gh-proxy, toolsets: [repos, actions] }` +
    `tools.edit` + `tools.cli-proxy: true` (required by the `pi` engine) —
    read access to the failed run's jobs/logs and to repository files.
  - `network.allowed: [defaults, github, threat-detection]` — no wildcard
    egress.
  - `safe-outputs.create-issue` (`max: 1`, labeled
    `automation, ci-investigation`) — the only permitted side effect,
    executed in a separate job gated by `gh-aw`'s built-in threat-detection
    job, never by the agent job itself.
  - `runs-on: [self-hosted, linux, private-lab, docker]` — the M2 runner.
- `.github/workflows/investigate-failure.lock.yml` — compiled via
  `gh aw compile` (committed alongside the Markdown source, per `gh-aw`
  convention: Actions executes the `.lock.yml`, not the Markdown).
- `.github/aw/actions-lock.json`, `.gitattributes` — `gh-aw`-generated
  action-pin cache and `linguist-generated=true` marker for `*.lock.yml`.
- `docs/security.md` — new "M10" section documenting the reasoning
  boundary and two open, unresolved limitations found during live E2E
  (below).

## Compilation evidence

```
$ gh aw compile
✓ .github/workflows/investigate-failure.md (105.7 KB)
✓ Compiled 1 workflow: 1 succeeded, 0 warnings
```

## Manual E2E Test — executed for real, not simulated

1. **Push a known-good commit** (`e74d2e2`) — `local-capability` ran on
   GitHub-hosted `ubuntu-latest` and **succeeded**
   ([run 33191431595](https://github.com/tbrandenburg/devenv-cloud/actions/runs/33191431595));
   `investigate-failure` correctly **skipped** (its `if:` guard rejects a
   `success` conclusion) — [run 33191447799](https://github.com/tbrandenburg/devenv-cloud/actions/runs/33191447799).
2. **Seed a known build failure** (`5abab01`, changed
   `examples/hello-service/hello.py`'s `greeting()` return string so
   `test_hello.py`'s assertions fail) and push to `main`.
3. **Observe deterministic CI fail — real, not simulated:**
   ```
   $ gh run list --workflow=local-capability.yml --limit 3
   completed  failure  ...  local-capability  main  push  33191512636  12s
   ```
4. **Trigger `gh-aw` — real, not simulated:** the `workflow_run` event
   fired automatically; `investigate-failure`'s `pre_activation` and
   `activation` jobs completed successfully and the `agent` job was queued
   for the `[self-hosted, linux, private-lab, docker]` runner:
   ```
   $ gh run list --workflow=investigate-failure.lock.yml --limit 3
   in_progress  ...  CI Failure Investigator  main  workflow_run  33191530756
   ```
5. **Start the M2 JIT runner for real** (`scripts/runner-jit-start.sh`) so
   the queued `agent` job could actually execute:
   ```
   Current runner version: '2.337.0'
   Listening for Jobs
   Running job: agent
   Job agent completed with result: Failed
   Removed .credentials / .runner (auto-deregistered, per M2 JIT design)
   ```
6. **Review the agent's actual failure output** (not the reasoning content
   — the job never reached the reasoning step):
   ```
   ! '/var/run/docker.sock' does not exist on this runner.
   X Cannot determine Docker socket group for '/var/run/docker.sock'.
     Set GH_AW_DOCKER_SOCK_PATH and GH_AW_DOCKER_SOCK_GID to configure the
     socket path and group explicitly.
   ```
7. **Verify no unauthorized action occurred:** the `agent` job failed
   before `safe-outputs`/issue-creation ran; no issue, PR, commit, or
   infrastructure change was produced by the investigator. `contents:
   read`/`actions: read` were the only permissions the (failed) agent job
   held.
8. **Cancelled** the stalled downstream `detection` job (queued for a
   runner that no longer existed after the JIT container auto-exited) and
   **reverted** the seeded failure (`f5c7a18`), restoring `main` to green:
   ```
   $ gh run list --workflow=local-capability.yml --limit 1
   completed  success  Revert "m10 e2e: seed known local-capability failure..."
   ```

## Open, unresolved limitations (documented, not silently worked around)

Both are recorded in `docs/security.md` under "M10":

1. **Docker-socket-proxy incompatibility.** `gh-aw`'s MCP Gateway/AWF
   sandbox requires a real Docker Unix socket (or
   `GH_AW_DOCKER_SOCK_PATH`/`GH_AW_DOCKER_SOCK_GID` naming one);
   `DOCKER_HOST=tcp://...` (M2's socket-proxy mitigation) is explicitly
   unsupported for this purpose per `gh-aw`'s own self-hosted-runner docs.
   Bind-mounting the real socket would reopen the unauthenticated-root risk
   M2 deliberately avoided, so this was **not** done as a workaround here.
   A dedicated resolution (e.g., a second, narrowly-scoped Docker daemon
   for `gh-aw` jobs) is left as explicit follow-up work.
2. **No AI engine credentials.** `gh secret list` returns empty — no
   `COPILOT_GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, or `OPENAI_API_KEY` is
   configured, so even past limitation (1) the `pi` engine has no model
   backend to call. Provisioning one is a repository-owner action.

Because of these two infrastructure/credential gaps, the *reasoning
content* of a real agent investigation (steps 3–4 of the Validation
Milestone: "agent investigates" → "result is visible in GitHub") could not
be exercised end-to-end in this environment. Everything upstream of the
model call — trigger wiring, permission scoping, safe-outputs
configuration, network allowlisting, and self-hosted-runner job pickup —
was exercised for real and is confirmed working.

## Lessons learned

- `gh-aw` v0.86.2 (installed via `gh extension install github/gh-aw`,
  latest per `gh extension upgrade`) rejects a nested `conclusion:` filter
  under `on.workflow_run:` even though the current hosted docs
  (`https://github.github.com/gh-aw/reference/triggers/`) show it as valid
  syntax — use a top-level `if: github.event.workflow_run.conclusion ==
  'failure'` guard instead until the installed CLI catches up with the
  docs.
