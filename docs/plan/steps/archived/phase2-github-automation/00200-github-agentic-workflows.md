> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 2 — GitHub Automation Backbone

## M10 — GitHub Agentic Workflows

### Objective

Add `gh-aw` (repository-centric reasoning) without replacing normal Actions.

```text
GitHub event
    ↓
gh-aw
    ↓
reason
    ↓
safe decision
    ↓
deterministic workflow
```

`gh-aw`'s reasoning step should invoke the harness chosen in Phase 1 M9 (`opencode` or `pi`) where a local agent CLI is needed, rather than introducing a third tool. `gh-aw` (`github/gh-aw`) explicitly supports GitHub Copilot, Claude Code, OpenAI Codex, Gemini, and **Pi** as engines — confirm the `pi` engine option against current `gh-aw` docs at implementation time.

### First Agentic Workflow

`gh-aw` source files live in the **same directory as regular Actions workflows**, not a separate one — create `.github/workflows/investigate-failure.md`, then run `gh aw compile` to generate the executable `.github/workflows/investigate-failure.lock.yml` sibling. Commit both — Actions executes the compiled `.lock.yml`, not the Markdown source.

It should:

1. inspect a failed Actions run
2. inspect relevant repository files
3. describe probable root cause
4. create a bounded output

Do not initially let it: deploy, modify infrastructure, control Docker host arbitrarily, or manipulate hardware. Enforce this with `gh-aw`'s documented **"safe outputs"** mechanism (a separate, permission-scoped job for validated writes) rather than relying on the prose constraint alone.

**Also enforce network and permission boundaries, not just request them:** since this runs on a self-hosted runner, configure gh-aw's Agent Workflow Firewall (`network: { firewall: true, allowed: [...] }` in frontmatter) scoped to only the domains the investigation needs — unrestricted egress on a self-hosted runner could exfiltrate data or reach internal-only services, violating Rule 6. Also declare an explicit minimal `permissions: { contents: read }` block rather than relying on safe-outputs' default alone.

**CORRECTION (post-M2 review, verified `gh repo view --json visibility` at review time):** `tbrandenburg/devenv-cloud` is currently **PUBLIC**, not private (open risk tracked in `docs/security.md` since M2, not yet resolved by the repo owner). Do not assume "private repo" when scoping this step — `gh-aw`'s public-repo integrity auto-filtering **does** apply here and must not be disabled or bypassed. Re-check visibility with `gh repo view --json visibility` at implementation time before finalizing the trigger/permission model, since this could change before M10 is reached.

### Keep Deterministic Capabilities Separate

Example normal workflow: `.github/workflows/local-capability.yml`, performing build/test/simulation. The agent can request the capability but should not reimplement it itself.

### Validation Milestone M10

Create a known build failure. Expected lifecycle: CI fails → agentic workflow executes → agent investigates → result is visible in GitHub.

### Manual E2E Test M10

1. Introduce the documented test failure.
2. Push branch.
3. Observe deterministic CI fail.
4. Trigger or observe `gh-aw`.
5. Review agent reasoning.
6. Verify the agent did not perform unauthorized actions.

Record in `docs/milestone-reports/M10-gh-aw.md`.
