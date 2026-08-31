---
name: coder-app-tile
description: Use when adding a new Coder dashboard tile (coder_app resource) that links a workspace out to an external service's UI - e.g. integrating a new app/tool like Temporal, omnigent, Grafana, or any future service into a Coder workspace template (coder/templates/*/main.tf). Covers external-link gating, icon size limits, public-vs-internal URL variables, and deep-link param verification. Trigger on "add a dashboard tile", "coder_app", "integrate <service> into the workspace", "app integration with a tile".
---

# Coder dashboard-tile app integration

This repo has integrated two external services into Coder workspace
dashboards so far (Temporal — Issue #50/#53/#55 — and omnigent — Issue
#43/#47). Both converged on the same shape through live trial-and-error.
There is deliberately **no shared Terraform module** yet (see AGENTS.md
"Guidelines" — only justified once a third integration needs it); copy the
pattern below by hand into the target template's `main.tf`, and re-verify
every constraint live rather than assuming it still holds — Coder version
upgrades or a new target service can invalidate any of these.

Reference implementations to copy from:
- `coder/templates/docker-workspace/main.tf` — `coder_app.temporal`
- `coder/templates/agent-workspace/main.tf` — `coder_app.omnigent`

## The pattern

```hcl
resource "coder_app" "my_service" {
  # Only if the tile should be conditional (see "Gating" below) — omit
  # `count` entirely for an always-on tile like code-server.
  count        = data.coder_parameter.my_service_owned.value ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "my-service"
  display_name = "My Service"
  external     = true                                  # see point 1
  icon         = "${var.my_service_public_url}/favicon.ico"  # see point 2
  url          = "${var.my_service_public_url}/some/deep/link"  # see point 3/4
}
```

## Checklist — verify each of these live, do not assume

1. **`external = true`, always — for services *not* reachable through the
   workspace agent.** Coder's own `coder_app` resource does support a
   non-external, embedded/proxied mode (`external = false` + `subdomain`/
   path proxying + `healthcheck`, see the official examples for
   code-server, JupyterLab, RStudio, Airflow at
   <https://coder.com/docs/admin/templates/extending-templates/web-ides> and
   the schema at
   <https://raw.githubusercontent.com/coder/terraform-provider-coder/main/docs/resources/app.md>)
   — this is **not** a Coder-version limitation as previously assumed. The
   catch: proxied mode only works for a process reachable *through the
   workspace agent itself* (`url = "http://localhost:PORT"`, proxied over
   the agent's own tunnel). Temporal's UI and omnigent's server are both
   separate, already-running containers on the platform's own Docker
   network, not processes inside the workspace agent — that's *why*
   `external = true` is correct for them, not because Coder can't do
   embedding at all. If a future integration's target service *is* a
   process the workspace agent itself starts/reaches (e.g. a tool the
   startup script launches on localhost), reconsider `external = false`
   with a `healthcheck` block instead of defaulting to `external = true`.

2. **Icon: `workspace_apps.icon` is `varchar(256)` in Coder's Postgres
   schema.** A `data:` URI (base64-embedded SVG/PNG) blows this limit for
   any real-world icon — verified live in Issue #47, `coder templates push`
   fails outright with `pq: value too long for type character varying(256)`,
   even for an 8×8px rasterized PNG. Use a real URL instead. **Check icon
   sources in this order before reaching for a custom favicon URL:**

   1. **Coder's own bundled icon set first** — `coder/coder`'s
      `site/static/icon/` directory
      (<https://github.com/coder/coder/tree/main/site/static/icon>) ships
      icons for dozens of common services (docker, github, jupyter,
      airflow, postgres, k8s, etc. — confirmed live via
      `curl -I https://raw.githubusercontent.com/coder/coder/main/site/static/icon/<name>.svg`,
      404 if absent; verified `postgres.svg` present, `temporal.svg` and
      `grafana.svg` absent as of this writing — always re-check the
      specific name you need, don't assume coverage). Coder's own official docs and provider schema
      recommend referencing these as
      `icon = "${data.coder_workspace.me.access_url}/icon/<name>.svg"`
      (see the provider's own example usage at
      <https://raw.githubusercontent.com/coder/terraform-provider-coder/main/docs/resources/app.md>) —
      this is same-origin with Coder itself, so it needs **no** CSP
      widening at all, unlike every external icon this repo has used so
      far. Always check this directory first; it's the zero-cost option.
   2. **The target project's own official brand/press-kit asset** (e.g. a
      small SVG favicon already served by the service itself, as done for
      Temporal and omnigent here) — only if step 1 has no match.
   3. **Simple Icons** (<https://simpleicons.org>) — a large, permissively
      licensed (CC0) set of brand SVG icons; confirmed live reachable
      (`https://simpleicons.org/icons/<name>.svg` returns `200` for common
      names like `temporal`, `grafana`). Coder's own official docs use
      this exact source for a third-party app (`portainer`) in their
      `coder_app` example. Only reachable if the workspace/browser can
      resolve `simpleicons.org` — see the dockerization note below for why
      that's undesirable on this platform.
   4. **Custom-hosted URL** (this repo's current pattern for Temporal/
      omnigent) — last resort, and only because both those services
      already serve their own favicon and are already a required runtime
      dependency (the browser must already reach them for `external = true`
      to work at all, so the icon fetch adds no *new* reachability
      requirement).

   If the icon URL isn't same-origin with Coder itself, you likely also
   need to widen `CODER_ADDITIONAL_CSP_POLICY`'s `img-src` in
   `compose.yaml` for that origin (found live 2026-08-31 for the omnigent
   tile) — and remember a `compose.yaml` env-var change needs the `coder`
   container actually recreated (`docker compose up -d coder`) before it
   takes effect; check `docker inspect coder --format '{{.Config.Env}}'`
   to confirm, don't trust the committed file alone.

   **Dockerizing/self-hosting an icon asset, if steps 1-4 above don't fit**
   (e.g. a future service with no bundled Coder icon and no small
   same-origin favicon of its own): given this platform's explicit
   no-inbound-Internet-exposure design goal, prefer serving the icon from
   an **already-running internal container** over adding any dependency on
   an external CDN (`simpleicons.org`, a project's public website, etc.)
   across the CSP boundary — every such external dependency is one more
   thing that can be unreachable/rate-limited/changed upstream, and widens
   `img-src` to a host outside this platform's own control. The minimal,
   concrete pattern for this repo: drop the (already-repo-committed-for-
   provenance, per Issue #47's `assets/` convention) SVG/ICO file into a
   directory already served statically by an existing internal service —
   e.g. reverse-proxied via `code-server`'s/`coder`'s own static file
   serving if the asset can live under an existing served path, or a tiny
   dedicated static-file container (a single-file `nginx:alpine` or
   `python:3-alpine -m http.server` service added to `compose.yaml`,
   mounting a repo-relative `assets/icons/` directory read-only) if no
   existing service's static root is appropriate. Either way the icon ends
   up same-origin-ish with the rest of the platform (internal Docker
   network + already-allowed CSP origin), not dependent on a public CDN
   staying reachable from a server with no inbound Internet exposure by
   design. Do not stand up a new dedicated service for this unless/until a
   third icon actually needs it — for one or two icons, bundling into an
   existing container's static assets is simpler and avoids YAGNI.

3. **Two URL variables, not one, if the target service also needs to be
   reached by the startup script / a backend process** (e.g. for
   login/registration calls): a `*_public_url` (browser-reachable, used in
   `coder_app.url`/`icon`) and a `*_server_url`/internal compose DNS name
   (used server-side). Do not reuse the internal one for `coder_app.url` —
   the browser can't resolve compose service names.

4. **Deep-link query params are target-specific — verify against the real
   service, don't assume support.** Temporal's `?query=WorkflowId STARTS_WITH
   ...` is real and confirmed working against Temporal UI 2.53.3. Omnigent's
   `?host=...` is currently INERT — the shipped web UI ignores unrecognized
   query params — kept only as forward-compatible plumbing pending upstream
   support (tracked: omnigent-ai/omnigent#5881). Before relying on any
   deep-link param, load the target URL with the param in a real browser
   and confirm it actually does something; document inertness explicitly in
   a comment if it doesn't, so a later reader doesn't assume it works.

## Gating: explicit boolean parameter, not name-sniffing

If the tile should only show for some subset of workspaces (e.g. only
workspaces a specific automated caller creates), gate it with an explicit
`mutable = true` boolean `coder_parameter` + `count = ... ? 1 : 0` —
**not** by sniffing the workspace name for a prefix convention. This was a
deliberate decision (Issue #53) specifically to avoid coupling tile
visibility to a naming convention that could change independently of the
template. See `data.coder_parameter.temporal_owned` in
`docker-workspace/main.tf` for the exact pattern, including its own comment
explaining the tradeoff.

If the tile's visibility depends on a caller elsewhere in the codebase
setting that parameter at workspace-create time (e.g. a Python
orchestrator's `DEFAULT_RICH_PARAMETER_VALUES` list, as Temporal's does in
`temporal/src/demo/workspace_activity.py`), add a **regression-guard test**
asserting that caller still sets it — see Issue #55 /
`temporal/tests/test_workspace_activity.py::test_default_rich_parameter_values_sets_temporal_owned_true`
for the exact shape. Do not rely on the Terraform default alone to catch
that class of regression; the default only applies at workspace-create
time for workspaces that don't pass the parameter explicitly at all.

## Authoritative external sources (verified reachable, real URLs)

- `coder_app` resource schema (fields, `healthcheck`, `share`, `open_in`,
  `hidden`, `group`, `order`, embedded-vs-external semantics):
  <https://raw.githubusercontent.com/coder/terraform-provider-coder/main/docs/resources/app.md>
  (mirrors <https://registry.terraform.io/providers/coder/coder/latest/docs/resources/app>,
  which requires JS to render).
- Coder's own official "Web IDEs" guide — real `coder_app` examples for
  code-server, VS Code Web, JupyterLab, RStudio, Airflow, File Browser,
  including embedded (`external` unset, `subdomain = true` +
  `healthcheck`) and third-party-external (Portainer, using a
  `simpleicons.org` icon) patterns side by side:
  <https://coder.com/docs/admin/templates/extending-templates/web-ides>
- Coder's bundled icon set (check here first for any well-known tool/
  service before sourcing a custom icon):
  <https://github.com/coder/coder/tree/main/site/static/icon>
- Simple Icons (CC0-licensed brand SVGs, Coder's own docs use this exact
  source for third-party apps): <https://simpleicons.org>

These confirm the existing repo-specific findings below still hold (the
`varchar(256)` icon-column limit, the CSP/`img-src` interaction, the
public-vs-internal URL split) — this is external validation of hard-won
lessons, not a replacement for them.

## Validation before calling an integration done

- `terraform validate` in the target template directory.
- `coder templates push <template> -d coder/templates/<template> --yes`,
  then create (or reuse) a real workspace and confirm the tile actually
  renders with a working icon in a real browser session (check
  `page.on('console')` for CSP violations — a broken icon can look
  identical to a correct one in a quick glance, only the browser console
  reveals a CSP denial).
- Click through the tile's external link and confirm it lands where
  expected; if it carries a deep-link param, confirm the param actually
  has an effect (see point 4).
