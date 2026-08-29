# Coder AI integration (Issue #13)

Status, entitlement boundaries, and the operational model for the Coder AI
providers/models/Chats integration on this deployment. This is a record of
what was verified against a live, unlicensed Coder server, not a feature
pitch — read `docs/security.md` and `AGENTS.md` for related boundary and
governance context.

## Entitlement matrix (verified against the live deployment)

| Capability | Status | Evidence |
|---|---|---|
| AI Gateway (`aibridge`) | Not entitled | `GET /api/v2/ai-gateway/openai/v1/models` → `403 {"message":"AI Gateway is a Premium feature. Contact sales!"}`; entitlement flag `aibridge = not_entitled` |
| Agent Firewall (Coder-native, `boundary` entitlement) | Not entitled | Entitlement flag `boundary = not_entitled` — see `governance/boundary/config.yaml`, which runs the OSS `boundary` CLI directly instead |
| AI Governance Add-On | Not entitled | Entitlement flags `ai_governance_user_limit` / `managed_agent_limit` / `workspace_external_agent` = `not_entitled` |
| Coder Agents (Chats API) | Works | `GET /api/experimental/chats` → `200 []` |
| Provider CRUD | Works | `POST /api/v2/ai/providers` → `201` |
| Model CRUD | Works | `POST /api/experimental/chats/model-configs` → `201` |
| Coder Tasks | EOL | Removed starting v2.37 (2026-09-01); Tasks docs state support "through Coder v2.36" only |

Three Premium/Add-On surfaces (AI Gateway, Coder-native Agent Firewall, AI
Governance Add-On) are unavailable on this deployment. Everything else in
this document — providers, models, Chats, MCP wiring — works unlicensed
and is what this integration is built on.

## Why Coder Tasks is not used

Coder Tasks is removed starting v2.37 (2026-09-01); Coder's own docs say it
was supported "through Coder v2.36" and its successor (Enterprise Session
Recording / ESR-adjacent functionality) is Premium-only thereafter. This
integration targets Chats (`/api/experimental/chats`), the unlicensed
successor surface, instead of building against a component already
scheduled for removal.

## Agents is not a workflow engine

Coder's own background-task reference diagram for "agentic coding"
describes roughly ten steps: Bug filed → CI trigger → Spin up workspace →
Analyze → Implement → Run tests → Open PR → Review → Merge → Deploy. Coder
itself owns exactly two of those: **spin up workspace** and **run the
agent inside it**. Every other box belongs to something else already in
this platform:

| Step | Owner |
|---|---|
| Trigger (bug filed / CI event) | GitHub Actions / gh-aw |
| Spin up workspace | Coder |
| Run the agent (analyze, implement, run tests) | Coder (Chats) |
| Open PR | GitHub (via the agent's own git push + `gh pr create`, or a safe-output action) |
| Review / merge / deploy | GitHub (branch protection, human or automated review) |

When Coder's own materials say "workflow" in this context, they mean a
**captured, reusable task definition running in a reproducible
environment** — not an orchestration engine with scheduling, retries, or
event triggers. There is no Coder Agents CLI and no built-in trigger
mechanism; automation against Chats is raw REST calls made by something
else. Temporal (durable orchestration) and gh-aw (GitHub-event-triggered
agentic workflows) remain the actual workflow layer in this platform;
Coder Agents/Chats is the execution surface they call into, not a
replacement for either.

## The repeatability model

A Chats-driven task is only as repeatable as four independently-controlled
inputs:

1. **Environment determinism** — the workspace runs a pinned Coder
   template (this repo's `docker-standard` / `agent-workspace` /
   `embedded-linux`), not an ad-hoc environment. See `AGENTS.md`'s
   Terraform/Coder lessons for what breaks this (e.g. unpinned volume
   names, dirty-tree template builds).
2. **Instruction determinism** — the prompt passed to Chats is versioned
   (checked into this repo or the calling automation), not typed ad hoc.
   A `.agents/skills/` directory (reusable, named prompt/instruction
   fragments) is a plausible future extension point for this but is
   **out of scope and not implemented** in this step — noted here only
   so it isn't rediscovered as a surprise later.
3. **Tool bounding** — what the agent can reach is constrained by
   `.mcp.json` (which MCP servers it can call) and OPA policy (what
   those servers actually allow it to do), not by trusting the model's
   judgment. See `governance/` and `coder/templates/agent-workspace/main.tf`.
4. **Deterministic verification** — a task is judged done by the test
   suite / CI result, never by the agent's own self-report. This is the
   same principle already enforced elsewhere in this repo ("features are
   either 100% working or 100% broken" — see the master `AGENTS.md`).

## The `waiting`-status trap

A Chat's status field is `waiting` when it is idle and expecting more
input. This is **not** a terminal-success state — it is also the status
of:

- a brand-new Chat that has not yet produced any output, and
- a Chat whose agent process was interrupted mid-task.

A polling loop that treats `waiting` as "the agent is done, check the
result" reports **false green** in both of the above cases. Any
automation built against Chats must poll for an explicit terminal
status/marker in the agent's own output (or a side-channel signal, e.g. a
file written on completion) — never `status == "waiting"` alone.

## Adding a provider or model

Providers and models are declarative — edit `coder/ai/providers.yaml` /
`coder/ai/models.yaml`, then run `make ai-bootstrap` to reconcile the
change into the running Coder deployment. Full mechanics (unique-name
rule, `default: true` model requirement, `api_key_env` indirection) are in
`coder/ai/README.md` — not duplicated here.

### Pointing at a local OpenAI-compatible model

`coder/ai/providers.yaml` ships a commented-out example provider entry
(`type: openai-compat`, `base_url:
http://host.docker.internal:11434/v1`) for a local Ollama/LiteLLM-style
endpoint. Uncomment and adjust `base_url`/`api_key_env`, add a matching
model entry in `models.yaml` with `provider: local-llm`, then run
`make ai-bootstrap`.

## MCP wiring

Two supported paths:

- **Local stdio** — `coder exp mcp server`, run inside the workspace
  itself; no network hop.
- **Remote HTTP** — see `coder/templates/agent-workspace/main.tf`'s
  `.mcp.json` generation for the `lab-sim` MCP server
  (`http://lab-sim:8300/mcp/`), including its optional bearer-token
  parameter (`LAB_SIM_AGENT_TOKEN`). That file is the reference
  implementation for wiring any additional remote MCP server into a
  workspace's `.mcp.json`.

## Secret handling — OpenBao migration (not implemented yet)

`api_key_env` in `providers.yaml` is never a literal secret, only the
name of an environment variable holding one; `scripts/ai_bootstrap.py`'s
`resolve_secret()` is the single place a secret value is ever read. It
already recognizes a `CADE_SECRET_BACKEND=openbao` mode but that branch
currently raises `NotImplementedError("OpenBao secret backend not yet
implemented for resolve_secret()")` — the OpenBao read path is a stub,
not a working integration. Until it's implemented, provider API keys are
resolved from `.env`/environment only.

## CI / unattended automation successor path (Task 8c)

Coder's own migration guidance for automating Tasks-era CI steps points at
a GitHub Action, renamed alongside the Tasks → Chats transition:

- **`coder/create-task-action` → `coder/create-agent-chat-action`** — pin
  the successor action at `@v0`.
- Input renames: `coder-task-prompt` → `chat-prompt`. The old
  `coder-template-name` and `coder-task-name-prefix` inputs are gone
  entirely (no direct replacement in the new action).
- **`organization_id` is required** on `POST /api/experimental/chats`
  (returns `400` without it) — Coder's own migration-guide test snippet
  omits it and is wrong; do not copy it as-is.
- Because the new action has no equivalent of "create-or-find a
  workspace by template name," a deterministic automation pattern is to
  **pre-create the workspace explicitly** via `POST
  /api/v2/users/{user}/workspaces` with a specific `template_id`, then
  pass the resulting `workspace_id` into the Chats-creation call —
  rather than relying on the action to resolve a template name to a
  workspace implicitly.
- This is a documentation-only note on the successor path required by
  Task 8c of Issue #13. **No migration/bridge code, CI workflow, or
  action wiring is implemented in this step** — this describes the path,
  it does not build it.

Coder Agents/Chats provides none of the following on its own:
scheduling, retries, or event triggers. Temporal and gh-aw remain the
workflow layer that would call into this successor action; Chats/the new
action is only the execution surface.

## Known limitation restated

AI Gateway, Coder-native Agent Firewall, and the AI Governance Add-On are
all Premium/Add-On surfaces this deployment does not have (see the
entitlement matrix above). The OSS `boundary` CLI (`governance/boundary/config.yaml`)
substitutes for Agent Firewall at the cost of control-plane audit log
streaming — a deliberate, documented gap, not an oversight.
