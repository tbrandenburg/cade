# Issue #60 — JupyterLab and Node-RED as optional per-workspace app tiles (docker-workspace)

Date: 2026-08-31
Scope: `coder/templates/docker-workspace` only (per issue's own scope note;
`agent-workspace`/`embedded-linux`/`devcontainer` deliberately deferred).

## Summary

Added two independent, opt-in dashboard tiles to the `docker-standard`
(`docker-workspace`) Coder template: JupyterLab and Node-RED, both run as
plain in-workspace processes (not platform `compose.yaml` services),
bound to `127.0.0.1` inside the workspace container, reachable only
through Coder's own authenticated agent proxy. Both default `false` —
zero behaviour change for existing workspaces.

## What changed

- `coder/Dockerfile`: two new `RUN` layers baking JupyterLab (own venv,
  PEP-668-safe) and Node-RED (+ `@flowfuse/node-red-dashboard` +
  `@tbrandenburg/node-red-agents`, installed globally) into
  `cade/coder-workspace:latest`.
- `coder/workspace-apps/node-red-settings.js` (new): no `adminAuth`,
  runtime-overridable base path (defaults to root).
- `coder/templates/docker-workspace/main.tf`: `enable_jupyter` /
  `enable_nodered` parameters (both default false), `coder_script.jupyter`
  / `coder_script.nodered` (idempotent via PID-file, not `pgrep -f`),
  `coder_app.jupyter` / `coder_app.nodered` (same-origin icons,
  `healthcheck` blocks).
- `coder/templates/docker-workspace/variables.tf`: `nodered_icon`
  override variable.
- `scripts/set-workspace-parameter.sh` (new): generic retro-fit
  mechanism, extracted from `set-workspace-temporal-tile.sh`.
- `scripts/set-workspace-jupyter.sh`, `scripts/set-workspace-nodered.sh`
  (new): thin wrappers.
- `scripts/set-workspace-temporal-tile.sh`: reduced to a thin wrapper,
  CLI contract byte-compatible.
- `scripts/verify-workspace-jupyter.sh`, `scripts/verify-workspace-nodered.sh`
  (new): live HTTP/process/port verification.
- `docs/operations.md`, `docs/security.md`,
  `coder/templates/docker-workspace/README.md`,
  `.agents/skills/coder-app-tile/SKILL.md`, `AGENTS.md`: documentation.

## Critical design correction found during live verification

The issue's own plan (setting `--ServerApp.base_url`/`NODE_RED_BASE_PATH`
to the full `/@owner/workspace.../apps/<slug>` prefix, matching the
conventional JupyterHub-style reverse-proxy pattern) was implemented
first, `terraform validate`d, and initially appeared to work — a direct
`docker exec <container> curl` to the full prefixed path returned 200 for
both apps.

Deep live verification through the REAL Coder dashboard proxy (not a
direct container curl) then found **every single request 404ing** for
both apps configured that way. Root-caused with an unambiguous
reproduction: swapped a raw Python `http.server` echo handler in for the
real app on the same port, and hit it through the real dashboard proxy —
the echo handler printed the exact bare path (`/foo`, `/somepathXYZ`) and
headers it received. **Coder v2.36.3's real path-based `coder_app` proxy
strips the `/@owner/workspace.../apps/<slug>` prefix before forwarding
to the app's `url`, and sends no `X-Forwarded-Prefix` header.** This
contradicts the JupyterHub-style assumption baked into the issue's
original plan.

Fix: mount both apps at root (no base path/prefix configuration at all),
matching what the real proxy actually forwards. Re-verified through the
real dashboard proxy after the fix:

- **Node-RED**: fully working end to end — editor SPA loads (200), its
  own relative-path assets (`vendor/vendor.js`, etc.) load correctly
  through the proxy, `/flows` and `/nodes` (with `Accept: application/json`)
  both return correct JSON, both `@flowfuse/node-red-dashboard` and
  `@tbrandenburg/node-red-agents` are discovered.
- **JupyterLab**: main page (`/lab`) and API (`/api`) routes now work
  (200) through the real proxy, but JupyterLab's own JS/CSS bundle is
  referenced via domain-absolute paths (`/static/lab/...`), which escape
  the app's own proxy scope once the browser is navigated to the tile's
  prefixed URL — a real, live-verified, NOT-fixed-here limitation. See
  "Follow-up issues found" below.

This is documented in `docs/operations.md`, `docs/security.md`,
`.agents/skills/coder-app-tile/SKILL.md`, and `AGENTS.md`'s Lessons
Learned.

## Validation run

```
$ cd coder/templates/docker-workspace && docker run --rm -v "$PWD":/wd -w /wd hashicorp/terraform:1.9 validate
Success! The configuration is valid.

$ make coder-workspace-build
... (builds cleanly, see below for size delta)

$ docker inspect cade/coder-workspace:latest --format '{{.Size}}'
2143475910   # baseline (pre-Issue-#60) was 1637770981 -> delta 482 MB, under the 800 MB threshold
```

Live round trip against the real running platform stack (`coder`,
`coder-db` already up; no other services touched):

```
$ coder templates push docker-standard -d coder/templates/docker-workspace --yes
Updated version at Aug 31 21:23:04!

$ coder create issue60verify --template docker-standard \
    --parameter github_token= --parameter agent_capable=false \
    --parameter temporal_owned=false \
    --parameter enable_jupyter=true --parameter enable_nodered=true --yes
The issue60verify workspace has been created at Aug 31 21:24:24!

# app health via API:
jupyter healthy
nodered healthy

# through the REAL dashboard proxy (Coder-Session-Token header, real access URL):
GET /@issue45verify/issue60verify.main/apps/jupyter/api   -> 200
GET /@issue45verify/issue60verify.main/apps/jupyter/lab   -> 200
GET /@issue45verify/issue60verify.main/apps/nodered/      -> 200 (1733 bytes)
GET /@issue45verify/issue60verify.main/apps/nodered/vendor/vendor.js -> 200
GET /@issue45verify/issue60verify.main/apps/nodered/flows (Accept:json) -> 200 []
unauthenticated GET .../apps/jupyter/api -> 303 (redirect to login, not 200)

$ scripts/verify-workspace-jupyter.sh issue45verify/issue60verify
Summary: 5 passed, 0 failed.

$ scripts/verify-workspace-nodered.sh issue45verify/issue60verify
Summary: 6 passed, 0 failed.
```

Default-off behaviour (both parameters `false`):

```
$ coder create issue60verify --template docker-standard \
    --parameter github_token= --parameter agent_capable=false \
    --parameter temporal_owned=false \
    --parameter enable_jupyter=false --parameter enable_nodered=false --yes
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.   # (vs. 9 when both true — no jupyter/nodered resources at all)

$ docker exec coder-issue45verify-issue60verify pgrep -af "jupyter\|node-red"
(exit code 1 — no matching process)

$ docker inspect coder --format '{{.Config.Env}}' | grep -o 'CODER_ADDITIONAL_CSP_POLICY=[^ ]*'
CODER_ADDITIONAL_CSP_POLICY=img-src   # byte-identical before/after this issue
```

All throwaway workspaces (`issue60verify`, both variants) were deleted
after verification. No `agent-workspace`/`embedded-linux`/`devcontainer`
templates or files were touched (per scope).

## What was NOT verified (honest gaps)

- JupyterLab's real browser-rendered UI was not visually confirmed in an
  actual browser session (only HTTP-level checks via `curl` — see the
  known limitation above; a real browser would show a broken/unstyled
  page since its JS bundle 404s once past the initial HTML load).
- The rename-without-rebuild regression test the issue suggested as
  lower priority (rename a running-app workspace, confirm the tile still
  works) was not run — out of scope given time budget, and less relevant
  now that the design no longer bakes owner/workspace name into any
  script (both apps mount at root).
- No test was run of `agent_capable`/`temporal_owned` interacting with
  the new parameters (e.g. all four true simultaneously) — each was only
  tested independently/in the two documented combinations above; no
  interaction bug is expected (all are independent `count` gates on
  disjoint resources) but this was not exhaustively proven.

## Follow-up issues found

1. **JupyterLab's browser UI does not fully render through Coder's
   path-based proxy tile** (this issue's own scope, documented as a known
   limitation rather than silently worked around — see
   `docs/operations.md`). Root cause: Coder v2.36.3's real `coder_app`
   path-proxy strips the URL prefix before forwarding, while JupyterLab's
   own static assets are referenced via domain-absolute paths. Two
   possible fixes for a follow-up issue: (a) enable wildcard DNS +
   `subdomain = true` for this specific app (matches Coder's own official
   recommendation, but requires infrastructure this deployment does not
   have per the issue's own pre-check); (b) add a small in-workspace
   path-rewriting reverse proxy (e.g., a ~30-line script that reads
   Jupyter's own asset requests and serves them under the correct
   prefix) — meaningfully more complexity than this issue's stated scope
   allows. Interim workaround documented: `coder port-forward <ws> --tcp
   8888:8888` + browse to `http://localhost:8888/lab` directly.
2. **`@tbrandenburg/node-red-agents@0.3.7` declares `engines.node >=22`**
   but this image installs Node.js 20 (`ARG NODE_MAJOR=20`, an existing,
   unrelated pin) — `npm install` only warns (`EBADENGINE`), does not
   fail, and the package loaded and functioned correctly in live testing
   (both `dashboard` and `agents` palette nodes were discovered and the
   flows/nodes API worked). Not blocking, but a future Node.js major
   version bump for this image should re-verify this package still works
   (or bump `NODE_MAJOR` to 22, out of scope for this issue since it
   would affect every other tool in the image, not just Node-RED).
