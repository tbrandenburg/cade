# Issue #13 — Coder AI Integration: E2E Test Report

Evidence captured for GitHub issue #13 (Integrate Coder AI: Agents,
providers/models, MCP server, agent firewall), executed against the live
stack per the issue's 14-test Manual E2E suite. No mocks, no dry runs.

- **Timestamp (UTC):** 2026-08-29T17:35Z–17:52Z
- **Environment:** local Coder server (`ghcr.io/coder/coder:v2.36.3`,
  `has_license: false`), new `agent-workspace` template built from this
  issue's `coder/agent-workspace/Dockerfile` (`FROM cade/coder-workspace:latest`
  + OSS `boundary` CLI v0.10.0), authenticated as an ad-hoc admin account
  minted by `scripts/ai-token.sh` (`cade-ai-bootstrap-1788025217` —
  documented residue, see "Known limitation" below).
- **Real OpenAI key:** **not available in this environment.** T3/T4/T9/T10/
  T12/T14 and the reconciler's HTTP contract were fully exercised for real
  against the live Coder API using a syntactically-valid placeholder key
  (`sk-test-placeholder-...`). T5, T11, and the tool-invocation half of T13
  were exercised as far as possible without a real key and are honestly
  reported as blocked at that specific point, not faked.

## Real bugs found and fixed during this test run (not by code review)

1. **`compose.yaml` crash-looped the entire `coder` container.** The
   `CODER_EXTERNAL_AUTH_0_*` block (Task 0) was originally wired
   unconditionally with `${GITHUB_OAUTH_CLIENT_ID:-}` defaults. Verified
   live (`docker logs coder`): Coder parses a provider config from the
   *presence* of `CODER_EXTERNAL_AUTH_0_ID` in its environment, not its
   value — `error: convert external auth config: "github" external auth
   provider: client_id must be provided`, then, even with the id itself
   emptied via `${VAR:+value}` substitution, `error: ... external auth
   provider "" doesn't have a valid id`. This would have broken `make up`
   for every fresh clone with no GitHub OAuth App configured (the default
   state). Fixed by commenting the block out by default (uncomment +
   fill in `.env` once a real OAuth App exists), matching this repo's
   existing convention for optional config (e.g. `coder/ai/providers.yaml`'s
   commented `local-llm` example).
2. **`scripts/ai_bootstrap.py`'s provider PATCH broke idempotency (T4).**
   `PATCH /api/v2/ai/providers/{name}` rejects the same `api_keys: [string]`
   body shape `POST` accepts (`400: "cannot unmarshal string into ...
   AIProviderKeyMutation"`), verified live. Every re-run after the first
   attempted (and failed) a PATCH, reporting the provider as `skipped`
   instead of `unchanged`. Fixed by comparing only the non-secret fields
   against the existing provider and skipping the API call entirely when
   they already match (mirrors the model-config path's existing
   skip-if-identical logic); `api_keys` is now never sent on PATCH.
3. **`governance/boundary/config.yaml`'s `jail_type: nsjail` default was
   wrong for this environment (T9).** Verified live against a real built
   image and a real workspace: `nsjail` fails with `setpriv: apply
   capabilities: Operation not permitted` — the same unprivileged-userns
   restriction already documented in `AGENTS.md` for `srt`'s
   `bwrap --unshare-user`. `landjail` (the issue's own documented fallback)
   works and genuinely enforces the allowlist. Default changed to
   `landjail` in both `governance/boundary/config.yaml` and the embedded
   copy in `coder/templates/agent-workspace/main.tf`.

## Test-by-test results

| Test | Result | Evidence |
|---|---|---|
| T1 `make up` survives missing key | **PASS** | Fixed bug #1 above first, then: `exit=0`, coder recreated healthy, exactly one `SKIP: CODER_SESSION_TOKEN not set...` line |
| T2 Token minting | **PASS** | `scripts/ai-token.sh` correctly detected no CLI session, printed the loud persistent-admin warning, created `cade-ai-bootstrap-1788025217`, printed the token once. (A first run's token was accidentally echoed to this session's own transcript by an insufficient redaction pattern in a manual validation command — immediately mitigated: password reset + `POST /api/v2/users/logout` confirmed the leaked token now returns `401`. This was a transcript-hygiene mistake in this test run, not a defect in the script itself, which never wrote the token to any file.) |
| T3 Bootstrap creates provider+model | **PASS** | `GET /api/v2/ai/providers` → 1 entry, `enabled:true`, key masked as `sk-t...0000` (never plaintext); `GET /api/experimental/chats/model-configs` → 2 entries, exactly one `is_default:true` (`gpt-4o-mini`, auto-defaulted as first-created) |
| T4 Idempotency (3x) | **PASS (after fixing bug #2)** | providers=1, models=2 after 3 runs; all report `unchanged` |
| **T5 Real inference (the "ruthless test")** | **BLOCKED — no real OpenAI key available** | Chat created successfully (`status: running`), but transitioned to `status: error` with `"Authentication with OpenAI failed"` — this is the expected, correct behavior for an invalid key, not a defect. The plumbing (org resolution, chat creation, model routing) is proven; genuine token-consuming inference is not. |
| T6 No secret leakage | **PASS** | `grep -c` of the real (placeholder) key in bootstrap output = 0; no `.env` staged; repo-wide `sk-[A-Za-z0-9]{10,}` grep only matches unrelated pre-existing text ("ris**k-acceptance**") in `docs/security.md`/`docs/INITIAL.md` |
| T7 Workspace has no LLM credentials | **PASS** | `docker exec <workspace> env \| grep -iE 'openai\|anthropic\|api_key'` → no match |
| T8 MCP server, both modes | **PARTIAL PASS** | Remote: `GET /api/experimental/mcp/http` → `200 text/event-stream` (not 404), confirms the endpoint is live. Local stdio: the `coder` binary exists at its workspace-injected path and runs `exp mcp server`, but requires an authenticated agent session ("You are not logged in") to actually serve — same class of limitation `AGENTS.md` already documents for AHP (no non-interactive substitute for a real client connection) |
| T9 Boundary enforcement | **PASS (landjail, after fixing bug #3)** | Live, inside the real workspace, config-file-only (no CLI override): `boundary --config ~/.boundary/config.yaml -- curl https://api.github.com` → `200`; same command against `https://example.com` → `403` from boundary's own proxy |
| T10 Durability Test 3 (`agent-workspace`) | **PASS** | Marker `20260829T174943Z-9586` written, `coder stop`+`start`, same `docker_volume.home_volume` ID (`coder-48a337aa-...-home`), byte-for-byte identical marker in the new container |
| T11 Bad key produces a clear error | **PASS** | `status: error`, `last_error: {"message":"Authentication with OpenAI failed. Check the API key and permissions.","kind":"auth","retryable":false,"status_code":502}` — actionable, not a silent hang or generic 500 |
| T12 AI Gateway limitation is honest | **PASS** | `GET /api/v2/ai-gateway/openai/v1/models` → exact `403 {"message":"AI Gateway is a Premium feature. Contact sales!"}`, matches `docs/ai-coder.md` |
| T13 Agent reaches `lab-sim` MCP tools + OPA deny | **PARTIAL — blocked at the same point as T5** | `.mcp.json` correctly written first-boot (`lab-sim` URL + `Bearer ${LAB_SIM_AGENT_TOKEN}` shell-expanded, empty since no token was supplied), `getent hosts lab-sim` resolves, chat created with `workspace_id` set (real `agent_id` resolved, confirming Coder correctly attached the chat to the workspace's agent) — but the chat fails at the same OpenAI-auth stage as T5 before ever reaching MCP tool discovery/invocation. The OPA-deny check could not be exercised without a real model turn actually calling `flash_device`. |
| T14 Cleanup | **PASS (with documented residue)** | `coder delete` succeeded (workspace + volume destroyed); `git status --short` clean repo-wide at each commit point. The ad-hoc admin account `cade-ai-bootstrap-1788025217` cannot delete/suspend itself (documented Coder limitation, `AGENTS.md` 2026-08-29) and no second admin session was available to remove it from outside — left as accepted, documented residue, its CLI session logged out |

## Known limitation carried forward

**A real, working `OPENAI_API_KEY` is required to close T5, T11's positive
counterpart, and the tool-invocation half of T13.** Everything upstream of
actual token-consuming inference — reconciler correctness, idempotency,
workspace isolation, MCP server liveness, egress enforcement, durability,
and error-path clarity — is proven with live evidence above. This is
consistent with the issue's own Definition of Done item ("T5 shows a
genuine model response — the feature is proven, not merely configured")
being the single hardest-to-satisfy criterion in a credential-less CI/sandbox
environment; it is called out here rather than silently skipped or faked.

## Definition of Done — status

- [x] All 14 E2E tests executed against the live stack, real output pasted above (T5/T13 explicitly partial, reason documented, not silently skipped)
- [x] `make up` exits 0 on a clone with no API key configured (after fixing bug #1)
- [x] `make ai-bootstrap` is idempotent across 3 consecutive runs, 0 duplicates (after fixing bug #2)
- [ ] T5 shows a genuine model response — **blocked, no real API key available in this environment**
- [x] No secret appears in any committed file, log, or script output (one transcript-hygiene mistake during manual T2 validation, immediately mitigated — see T2 row)
- [x] `agent-workspace` template passes Durability Test 3 in its own right
- [x] Boundary is enforcing (`landjail`, after fixing bug #3) — not merely documented as non-enforcing
- [x] `docs/ai-coder.md` states plainly what is unavailable without a license, with evidence
- [ ] Agent can call `lab-sim` MCP tools, and OPA still denies an unapproved `flash_device` — **blocked at the same missing-API-key point as T5**
- [x] Everything committed and pushed — `git status --short` clean across the whole repo before closing (verified before PR)
