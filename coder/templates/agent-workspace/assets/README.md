# assets/

`omnigent-icon.svg` is a verbatim copy of the real Omnigent favicon, fetched
live from a running `omnigent-server` container (`GET /favicon.svg`, part of
its own bundled frontend static assets — the same image also ships inside
the `cade/agent-workspace:latest` image via the vendored `omnigent` package).
Saved here for provenance and as a ready-to-use asset for a future fix.

**Not currently referenced by `main.tf`.** Issue #47 originally proposed
embedding this file directly into `coder_app.omnigent.icon` as a
`data:image/svg+xml;base64,...` URI via Terraform's `filebase64()`. Verified
live against the real Coder Postgres schema that this is infeasible:

```
$ docker exec coder-db psql -U coder -d coder -c "\d workspace_apps" | grep icon
 icon                  | character varying(256)   |           | not null |
```

The real favicon is 13,809 bytes raw (~18,412 base64 chars) — far beyond the
256-character column limit, and even a heavily downscaled 8x8px rasterized
PNG re-encoding of the same logo still needs ~526 base64 chars. `coder
templates push` fails with `pq: value too long for type character varying(256)`
for any encoding of the real asset tested.

`main.tf` instead references `"${var.omnigent_public_url}/favicon.svg"`
directly. This adds no *new* runtime dependency: `coder_app.omnigent` is
`external = true`, so the browser must already reach `omnigent_public_url`
directly to open the app at all — the icon fetch shares that same,
already-required reachability.

**A second, separate blocker was found (and fixed) during live coordinator
verification of this same URL approach**: Coder's dashboard ships a default
Content-Security-Policy (`img-src 'self' https: data: blob:`), which
silently blocks loading an `<img>` from a plain-`http` origin — confirmed
live via the browser's own console error (`Loading the image
'http://localhost:8000/favicon.svg' violates the following Content
Security Policy directive: "img-src 'self' https: data: blob:"`), even
though the network request itself would have succeeded. This platform has
no TLS termination in front of Coder/omnigent-server by design (see
`docs/INITIAL.md`, "no inbound Internet exposure"), so `https:` isn't an
option either. Fixed by widening the CSP for exactly this one
already-trusted internal origin via `CODER_ADDITIONAL_CSP_POLICY` in
`compose.yaml` (`img-src http://localhost:${OMNIGENT_PORT:-8000}`) — the
minimal widening that unblocks only the one icon `<img>` fetch. Verified
live end-to-end (real browser session, real Coder dashboard, real
workspace): the "Omnigent Chat" tile now renders the actual favicon.

If Coder ever widens `workspace_apps.icon`'s column limit (or adds a
template-bundled-asset serving mechanism), this file is ready to be
referenced via `filebase64("${path.module}/assets/omnigent-icon.svg")` as
originally proposed in issue #47 — at which point the `compose.yaml` CSP
widening above could likely be reverted too (a `data:` URI already
satisfies the default CSP).
