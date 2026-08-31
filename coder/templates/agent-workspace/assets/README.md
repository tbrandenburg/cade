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
directly — verified live to render correctly in the Coder dashboard (see
`docs/milestone-reports/issue-47-omnigent-icon.md` if present, or the
issue's own subagent handoff for the live verification evidence). This adds
no *new* runtime dependency: `coder_app.omnigent` is `external = true`, so
the browser must already reach `omnigent_public_url` directly to open the
app at all — the icon fetch shares that same, already-required reachability.

If Coder ever widens `workspace_apps.icon`'s column limit (or adds a
template-bundled-asset serving mechanism), this file is ready to be
referenced via `filebase64("${path.module}/assets/omnigent-icon.svg")` as
originally proposed in issue #47.
