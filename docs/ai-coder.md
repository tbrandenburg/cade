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
   template (this repo's `docker-workspace` / `agent-workspace` /
   `embedded-linux`), not an ad-hoc environment. See `AGENTS.md`'s
   Terraform/Coder lessons for what breaks this (e.g. unpinned volume
   names, dirty-tree template builds).
2. **Instruction determinism** — the prompt passed to Chats is versioned
   (checked into this repo or the calling automation), not typed ad hoc.
   `.agents/skills/` (reusable, named prompt/instruction fragments,
   `SKILL.md` with YAML frontmatter) is a real, working extension point
   for this — confirmed live in Issue #16 (see "Explored Agents
   capabilities" below). One committed example skill
   (`.agents/skills/repo-orientation/SKILL.md`) exists in this repo.
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

**Update (Issue #17, fully implemented and E2E-tested live):**
`.github/workflows/agent-chat.yml` implements this path end to end — a
real GitHub OAuth App (`GITHUB_OAUTH_CLIENT_ID`/`GITHUB_OAUTH_CLIENT_SECRET`
in `.env`) enabled `CODER_EXTERNAL_AUTH_0_*` in `compose.yaml`, wired into
the `agent-workspace` template's `data.coder_external_auth.github`
(falls back to the pre-existing manual `github_token` parameter for
unlinked users), triggering a real `coder/agents-chat-action@v0` run on
a real `agent-chat`-labeled issue.

Corrections to the assumptions above, found only by actually running it:
- The real published action is **`coder/agents-chat-action@v0`**, not
  `create-agent-chat-action@v0`.
- Its real inputs are `coder-url`, `coder-token`, `coder-organization`
  (an org **name**, not `organization_id`), `workspace-id`, `chat-prompt`,
  `github-url`, `github-token`, `force-new-chat` — there is no
  `organization_id` input at all; the action resolves the organization
  by name (or the token owner's sole membership) internally.
- **`github-url` must be a real issue/PR URL on `github.com`** — the
  action explicitly rejects bare repo URLs and non-github.com hosts
  (hardening against a workflow being tricked into redirecting to an
  attacker-chosen repo via templated user content). A `workflow_dispatch`
  dry-run therefore needs a real issue URL supplied via input, not the
  repo's own URL.
- **The action's chat-reuse mechanism is a real footgun.** It tracks a
  chat via a hidden HTML comment (keyed on `github-url` + workflow name)
  posted on the issue, and by default reuses that chat on a repeat run —
  silently ignoring whatever `workspace-id` the run just freshly
  pre-created. If the earlier run's workspace has since been deleted,
  the reused chat is left pointing at a dead workspace (`410`, verified
  live). `force-new-chat: true` is required to make each run's own
  pre-created workspace actually take effect, at the cost of chat
  history not persisting across repeat runs against the same issue.
- **Coder workspace names are capped at 32 characters.** A naming scheme
  that embeds both the issue number and the full numeric GitHub run id
  (e.g. `agent-chat-issue-17-run-33297380726`, 36 chars) is rejected by
  server-side validation; keep generated names short (the workflow uses
  `ac-<issue-or-wd>-<last 8 digits of run id>`).
- **Coder's `POST /api/v2/users/{user}/keys/tokens` `lifetime` field is
  nanoseconds** (`time.Duration`), not seconds — passing a plain
  seconds value (e.g. `7776000` for 90 days) silently creates a
  near-instantly-expiring token that then fails on its very next real
  use with an opaque `401`/"access token has expired", not an error at
  creation time. The server also caps the max lifetime at `168h` (7
  days) regardless of what's requested.
- `permissions: issues: write` (not just `contents: read`) is required
  for the action's own default `comment-on-issue: true` behavior to
  actually post its result comment back to the triggering issue.

**Real E2E evidence** (two full runs against this repo's real issue #17,
2026-08-30, self-hosted JIT runner per `scripts/runner-jit-start.sh` —
GitHub-hosted `ubuntu-latest` cannot reach `CODER_URL`, which is only
routable on this host's Docker network):
- Real `issues:labeled` trigger (not just `workflow_dispatch`) fired the
  workflow using the real label `agent-chat`.
- `chat-prompt` was built from the real issue's title + full body
  (verified in the run log), pre-creating a real Coder workspace from
  inside the CI job (`agent-workspace` template, build `succeeded`).
- A real Coder Agents chat was created against that workspace and did
  real, non-mocked LLM tool-calling work (`start_workspace`, `read_file`
  tool calls observed via `GET
  /api/experimental/chats/{id}/messages`, real token usage recorded).
- A real result comment was posted back to issue #17
  (`permissions: issues: write` + the action's `comment-on-issue`).
- A second run against the same issue, after the `force-new-chat: true`
  fix, was confirmed to create a genuinely new chat + new workspace
  rather than reusing the first run's (verified via the run log's
  `Agents chat created successfully` message and a differing chat id).
- All test workspaces and the `agent-chat` label were cleaned up after
  each run; the JIT runner auto-deregistered.

**External-auth token TTL — not independently re-verified.** The
issue's premise that an "~8-hour external-auth token TTL limitation" is
"already documented" in this file could not be substantiated: no such
claim exists anywhere in this repo prior to this update. GitHub OAuth
App user-to-server tokens do not expire by default unless "Enable
expiring user tokens" is turned on for the app (a setting only visible/
changeable on the app's own GitHub settings page, not queryable via the
API used in this session). Re-verifying the actual real-world TTL of a
linked token would require waiting out its real lifetime (hours), which
this session did not do — flagged here as an open, honestly-unverified
item rather than restated as fact.

## Explored Agents capabilities (Issue #16)

Six additional, already-live Coder Agents features (v2.36.3, no new
infra/template changes) tested against a real, throwaway `agent-workspace`
workspace (`issue16-test`, deleted after testing) with a real chat, `content`
message parts, uploaded files, and a real `OPENAI_API_KEY` reaching `gpt-4o`/
`gpt-4o-mini`. All calls used `POST/GET /api/experimental/chats` with a
Coder admin session token (`bash scripts/ai-token.sh`); no mocks.

| Feature | Status | Evidence |
|---|---|---|
| Sub-agent delegation (`spawn_agent`) | **Works** | Prompted a root chat to delegate three reports (backend/frontend/infra) to parallel sub-agents. `GET /api/experimental/chats/{id}` returned `status: "waiting"` with `children: [...]` containing 3 real child chats — `"Backend Structure Report"`, `"Frontend Structure Report"`, `"Infrastructure Structure Report"` — each with its own `id`, `parent_chat_id`/`root_chat_id` pointing at the parent, and its own `summary`. All three `created_at` timestamps are within the same second (`2026-08-30T05:14:24.70{4,6,8}Z`), confirming they ran in parallel, not sequentially. The root chat's own `summary` combined all three. No dedicated `list_agents`/`wait_agent` REST endpoint exists (`GET /api/experimental/agents` → `404`); `children` on the parent chat resource is the actual polling surface. |
| Plan mode | **Works** | Created a chat with `"plan_mode":"plan"` (the only accepted enum value found by probing; `on`/`enabled`/`always`/`true`/`"plan_first"` field name all rejected with `{"message":"Invalid plan_mode value."}`) and a prompt to edit `README.md`. Tool trace showed only `write_file` to `/home/coder/.coder/plans/PLAN-<chat-id>.md` (a `propose_plan` tool-result confirmed `path` under `.coder/plans/`); `docker exec <container> head -1 /home/coder/project/README.md` showed the file was **unmodified** afterward. Then `PATCH /api/experimental/chats/{id}` with `{"plan_mode":""}` → `204`, followed by a new user message "Implement the plan now." — the agent then actually edited `README.md` (`docker exec ... head -2 README.md` showed the new comment line present), proving normal-mode tool access resumed. |
| `.agents/skills/` | **Works** | Created `.agents/skills/repo-orientation/SKILL.md` (YAML frontmatter: `name`, `description`) — see that file in this PR's diff. Copied it into the running workspace's `/home/coder/project/.agents/skills/repo-orientation/` (via `docker cp`, since a real `agent-workspace` clones from `origin`, not this worktree — pushing was out of scope for this spike). Prompted a chat to look up the skill; tool trace showed a real `read_skill` tool-call with `args: {"name": "repo-orientation"}` and a tool-result `{"dir": "/home/coder/project/.agents/skills/repo-orientation", "body": "<the file's markdown body>", "name": "repo-orientation", "files": []}`; the assistant's final answer correctly quoted the skill's content verbatim. Unlike #13's T13 MCP-auto-discovery gap, this worked fully over the headless REST API with no interactive client needed. |
| `web_search` | **Entitlement gap (not available; deployment falls back to `execute`)** | Prompted a chat to "use your web_search tool" to look up a real, verifiable fact (the latest `coder/coder` GitHub release tag). The agent had no such tool available and instead emitted a `tool-call` for `execute` running `curl -s https://api.github.com/repos/coder/coder/releases/latest` from inside the workspace container, correctly reporting the real result (`v2.35.6`). No `web_search` tool-call ever appeared in the message trace — this deployment/provider config has no provider-native search tool wired up; the model substitutes its general-purpose shell `execute` tool instead. Recorded as an entitlement/configuration gap alongside the others below, not a Coder platform limitation per se — no first-party search-tool config was found in `coder/ai/providers.yaml`/`models.yaml` or the deployment config (`GET /api/v2/deployment/config`, grepped for `search`: no match). |
| `computer_use` sub-agent type | **Not entitled** | `GET /api/v2/entitlements` lists no `computer_use`/virtual-desktop feature flag at all (full `features` key list: `access_control, advanced_template_scheduling, ai_governance_user_limit, aibridge, appearance, audit_log, boundary, browser_only, connection_log, control_shared_ports, custom_roles, external_provisioner_daemons, external_token_encryption, high_availability, managed_agent_limit, multiple_external_auth, multiple_organizations, scim, service_accounts, task_batch_actions, template_rbac, user_limit, user_role_management, workspace_batch_actions, workspace_external_agent, workspace_prebuilds, workspace_proxy`); `GET /api/v2/experiments` returns only `["oauth2","mcp-server-http"]`. Confirmed directly and precisely by actually asking a chat to spawn one: the agent's own `spawn_agent` tool-call with `{"type":"computer_use", ...}` returned the exact error `{"error": "type \"computer_use\" is unavailable because the chat-virtual-desktop experiment is not enabled"}` — the agent then reported this limitation back verbatim in its final answer. This is the `chat-virtual-desktop` experiment (not currently in the enabled-experiments list above), a distinct gate from the entitlement-flag pattern used by `aibridge`/`boundary`/AI-Governance. |
| Image attachments | **Works** | Uploaded a real PNG (rendered via ImageMagick `convert`, containing the unique embedded string `ISSUE16-VISION-TEST-7f3a9c`, not present anywhere else in this repo or prompt) via `POST /api/experimental/chats/files?organization=<org-id>` with `Content-Disposition: attachment; filename="test.png"` → `{"id":"<file_id>"}`. Created a chat with `content: [{"type":"text","text":"What text do you see..."},{"type":"file","file_id":"<file_id>","media_type":"image/png"}]` (the `{"type":"image",...}` shape is rejected: `"content[1].type \"image\" is not supported"` — `"file"` with an image `media_type` is the correct part type). The model's real response was exactly `"ISSUE16-VISION-TEST-7f3a9c"` — proof the vision-capable model (`gpt-4o-mini`, `model_config_id: 30c462e7-ee28-4b4a-8bd6-8a40d6b97f6d`) actually received and read the pixel content of the attached image, not a hallucination or coincidence. |

Two REST-API mechanics discovered along the way, not previously documented
in this file: `POST /api/experimental/chats`'s `content` field is
`[]codersdk.ChatInputPart`, each part needs an explicit `"type":"text"` (a
bare string body is rejected with a Go-struct unmarshal error naming the
field/type); and file uploads for chats go through
`/api/experimental/chats/files?organization=<org-id>` (not the generic
`/api/v2/files` endpoint, which rejects non-tar content types), requiring
a `Content-Disposition: attachment; filename="..."` header.

## Omnigent opencode-native badge workaround (Issue #82)

Omnigent's own opencode-native harness readiness check
(`omnigent/onboarding/opencode_auth.py`) has no concept of OpenCode's free,
credential-less default "Zen" model (`opencode/big-pickle`) — it only
recognizes a stored `auth.json` provider entry or a provider env var as
"configured", and reports a `needs-auth` badge for any workspace running
purely on the free default model, even though that workspace's
`opencode-native` harness works perfectly fine. `coder/templates/
docker-workspace/main.tf` and `coder/templates/agent-workspace/main.tf`
both work around this, gated entirely behind `enable_omnigent=true`
(zero effect on workspaces that don't use Omnigent), purely cosmetically
— it satisfies the dashboard badge only, and must never be treated as a
path to a real, working OpenCode provider. A user who wants real
inference against a real provider should still run `omnigent setup`/
`opencode auth login` normally.

### Rejected variants (all confirmed live, not assumed)

1. **A dummy `OPENAI_API_KEY` or dummy `auth.json` entry, with no model
   pin.** Silently redirects OpenCode's own default-model selection away
   from `big-pickle` to whichever provider now looks "configured":
   ```
   $ OPENAI_API_KEY=sk-dummy... opencode run "say hi"
   > build · gpt-5.3-chat-latest
   Error: Incorrect API key provided: sk-dummy...
   ```
   This breaks the exact default behavior this repo's README documents
   as its out-of-the-box example (Journey 1) — rejected.

2. **A dummy `OPENAI_API_KEY` env var, even with the model pin in
   place.** Does not flip Omnigent's badge at all — confirmed via
   `/proc/<daemon-pid>/environ` showing the var is simply absent from the
   daemon process's environment.

3. **Root cause of (2), traced to the exact upstream code, not
   guessed:** `omnigent/cli.py`'s `_build_host_daemon_env()` has two
   different environment allowlists depending on daemon mode — in LOCAL
   mode (`server_url` unset) provider secrets like `OPENAI_API_KEY`/
   `ANTHROPIC_API_KEY` ARE forwarded to the daemon; in REMOTE mode
   (`server_url` set) they are explicitly excluded, by design, per the
   function's own docstring: a shared remote server shouldn't inherit
   the workspace owner's provider secrets just because its daemon runs
   there. Both `docker-workspace` and `agent-workspace` always invoke
   `omnigent host "$OMNIGENT_SERVER_URL" --background --non-interactive`
   — i.e. REMOTE mode, connecting to the shared `omnigent-server`
   container — so provider env vars are architecturally, deliberately
   never forwarded to the daemon process in this configuration. This is
   correct, intentional upstream security design, not a bug to route
   around via env vars — do not attempt to defeat it with a different
   env-var channel.

### What actually works, fully verified live, no side effects

1. **Pin the default model explicitly** in
   `~/.config/opencode/opencode.jsonc`:
   ```jsonc
   { "$schema": "https://opencode.ai/config.json", "model": "opencode/big-pickle" }
   ```
   Overrides OpenCode's own credential-presence-based default-model
   selection, so `big-pickle` stays active no matter what other (dummy)
   credentials exist.

2. **Write a dummy provider entry directly to the file**
   `~/.local/share/opencode/auth.json` — never an env var, must be the
   file, since omnigent's `_stored_providers()` re-reads it fresh from
   disk on every readiness check, entirely independent of the daemon's
   own filtered/stale environment. This is the only channel that
   actually reaches the readiness check in remote-daemon mode:
   ```json
   {"openai": {"type": "api", "key": "sk-dummy-placeholder"}}
   ```

With both in place: `opencode run "..."` still uses `big-pickle` and
works correctly, and Omnigent's own `/v1/hosts` API reports
`"opencode-native": true` instead of `"needs-auth"`.

### Idempotency / non-destructiveness

Both templates' startup scripts write these two files only when safe:

- `opencode.jsonc` is written only if the file doesn't already exist —
  never clobbers a real user-customized config (same copy-once guard
  pattern already used elsewhere in these templates, e.g. the
  `srt-settings.json` copy).
- `auth.json` is written only if the file doesn't already exist or is
  empty/`{}` — never overwrites a genuine `opencode auth login`
  credential a user may have since configured.

### Live verification performed for this issue

- `terraform fmt -check`/`terraform validate` passed clean for both
  `coder/templates/docker-workspace/` and `coder/templates/
  agent-workspace/` (containerized `hashicorp/terraform` image, no
  network-dependent host binary available in this environment).
- Static review confirmed both new blocks sit strictly inside the
  existing `if [ "${enable_omnigent.value}" = "true" ]; then ... fi`
  conditional in both files, immediately before the `omnigent host
  ... --background` invocation.
- Full live E2E (real workspace create, real `opencode run`, real
  `/v1/hosts` check, real browser Omnigent Chat tile turn) was not
  performed in this environment/session — see the accompanying
  handoff for exactly what was and wasn't exercised live. Re-verify
  against a real workspace before considering this fully closed.

## Known limitation restated

AI Gateway, Coder-native Agent Firewall, and the AI Governance Add-On are
all Premium/Add-On surfaces this deployment does not have (see the
entitlement matrix above). The OSS `boundary` CLI (`governance/boundary/config.yaml`)
substitutes for Agent Firewall at the cost of control-plane audit log
streaming — a deliberate, documented gap, not an oversight.
