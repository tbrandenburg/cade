#!/usr/bin/env python3
"""Issue #62: minimal in-workspace reverse-proxy shim for the JupyterLab tile.

Why this exists (see coder/templates/docker-workspace/main.tf's
coder_script.jupyter / coder_app.jupyter comments, and Issue #60/#62 for the
full history): Coder v2.36.3's real path-based `coder_app` proxy strips the
`/@owner/workspace.../apps/<slug>` prefix before forwarding a request to the
app's `url` — it never preserves the original path, and sends no
`X-Forwarded-Prefix` header. JupyterLab's own HTML/JS emits DOMAIN-ABSOLUTE
asset paths (e.g. `/static/lab/...`), which resolve against the bare origin
instead of the tile's actual prefixed browser location, so the editor UI's
own JS/CSS bundle 404s once you're in a real browser navigated to the tile.

Node-RED (also proxied through the same coder_app mechanism) works fine
because its own HTML emits RELATIVE asset paths ("vendor/vendor.js"), which
resolve correctly no matter what prefix the browser is actually on.

Fix: run this shim on the port the coder_app tile actually points at
(SHIM_PORT, default 8888), with the real `jupyter-lab` process moved to a
different internal-only port (BACKEND_PORT, default 8889). The shim proxies
every request through unmodified EXCEPT it rewrites a narrow, safe set of
domain-absolute asset references in HTML/JS/CSS responses
(`href="/...`, `src="/...`, and the JS string literal prefix `"/static/`)
into relative ones, exactly mirroring how Node-RED's own HTML already
resolves correctly. WebSocket upgrades (Jupyter's kernel/terminal comms) are
never inspected or rewritten — they're relayed as a raw, bidirectional byte
stream, so kernel execution is unaffected by this shim.

Stdlib only (http.server, http.client, socket, threading, re) — no new
Python packages need to be installed in coder/Dockerfile for this to work.

This shim adds NO new external exposure: like `jupyter-lab` today, it binds
127.0.0.1 only, so the sole way to reach it is still Coder's own
session-authenticated agent proxy.
"""
from __future__ import annotations

import http.client
import os
import re
import select
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("SHIM_PORT", "8888"))
BACKEND_HOST = "127.0.0.1"
BACKEND_PORT = int(os.environ.get("BACKEND_PORT", "8889"))

# Content types worth rewriting. Anything else (images, fonts, binary
# notebook/kernel payloads, JSON API responses, etc.) is streamed through
# byte-for-byte, untouched — narrow scope is deliberate, see module docstring.
REWRITE_CONTENT_TYPES = ("text/html", "application/javascript", "text/javascript", "text/css")

# Narrow, safe rewrites only:
#   href="/..."  -> href="..."
#   src="/..."   -> src="..."
#   '"/static/'  -> '"static/'   (JS string-literal asset references)
#   "xxxUrl": "/..." -> "xxxUrl": "..."   (see Issue #83 below)
# Intentionally does NOT touch "//" (protocol-relative URLs), query strings,
# or any occurrence not immediately following one of these exact markers —
# this avoids corrupting WebSocket URLs (ws://...), JSON payloads, or
# unrelated strings that merely contain a "/" character.
_HREF_SRC_RE = re.compile(rb'(href|src)="/(?!/)')
_STATIC_STR_RE = re.compile(rb'"/static/')

# Issue #83: JupyterLab's own root HTML embeds a `<script
# id="jupyter-config-data" type="application/json">` blob whose JS
# (`PageConfig`/`ServerConnection`) reads directly to build every API/WS
# request — e.g. `"baseUrl": "/"`, `"appUrl": "/lab"`,
# `"fullSettingsUrl": "/lab/api/settings"`, `"treeUrl": "/lab/tree"`, etc.
# Every one of these keys follows Jupyter's own naming convention of ending
# in "Url" (camelCase). Two DISTINCT bugs live here, and fixing only the
# first (as an earlier version of this shim did) is NOT sufficient — the
# second is the actual remaining blank/broken-editor defect re-scoped by
# Issue #83 (follow-up to #76/#81):
#
# Bug 1: these are domain-absolute JSON *string values*, never touched by
# the `href="/`/`src="/` HTML-attribute rewrites above, so with the value
# left as shipped (e.g. "/lab/api/settings") the browser fetches it
# straight from the bare domain root, bypassing the tile's proxy path
# entirely. Fixed the same narrow way as `href=`/`src=`: strip exactly one
# leading "/" (`_CONFIG_URL_RE` below).
#
# Bug 2 (the actual remaining gap): stripping the leading "/" makes the
# *string value* relative, but JupyterLab's `URLExt.join()`/
# `ServerConnection.makeSettings()` machinery does NOT resolve a relative
# `baseUrl` against the current page's directory the way a plain HTML
# `href="lab/api/settings"` would (confirmed live: even with `"baseUrl":
# ""` and `"settingsUrl": "lab/api/settings"`, the browser still requested
# the origin-absolute `http://<host>/lab/api/settings`, not the
# tile-prefixed URL) — it always resolves relative to the *origin root*,
# never to the actual browser-visible tile prefix
# (`/@owner/workspace.../apps/jupyter/`). The shim itself has no way to
# learn that prefix server-side (Coder sends no `X-Forwarded-Prefix`,
# see Issue #60), but the *browser* already knows it, in
# `window.location.pathname`, the instant the page loads. Fixed with a
# small inline `<script>` (`_CONFIG_PREFIX_SCRIPT`) injected immediately
# after the `jupyter-config-data` tag: it derives the real external prefix
# by stripping the config's own already-known `appUrl` suffix (e.g.
# "lab") off the live `window.location.pathname`, and sets `cfg.baseUrl`
# to it — this must run, and does run, before `jlab_core.js` (loaded
# later in the same document) ever reads the config.
#
# Deliberately does NOT also re-prefix every other already-relativized
# `*Url` field (an earlier version of this fix tried that and broke
# things): JupyterLab's own runtime code uses these two DIFFERENT ways
# for the *same* field depending on call site — some code paths read a
# field like `settingsUrl` as an already-fully-qualified literal, while
# others build the equivalent request via `URLExt.join(baseUrl,
# settingsUrl)`, joining it with `baseUrl` a second time. Only fixing
# `baseUrl` and leaving the individual fields exactly as the Python-side
# `_CONFIG_URL_RE` rewrite already left them (relative, no leading "/")
# lets the `join()` call sites resolve correctly (baseUrl + relative
# suffix = the one correct absolute path); re-prefixing the field's own
# value too would have made those call sites request a doubled,
# non-existent path (`.../apps/jupyter/@owner/workspace.../apps/jupyter/
# lab/api/settings`, confirmed live as a 404) instead.
_CONFIG_URL_RE = re.compile(rb'("\w*Url"\s*:\s*)"/(?!/)')

_CONFIG_DATA_TAG_RE = re.compile(
    rb'(<script\s+id="jupyter-config-data"[^>]*>.*?</script>)', re.DOTALL
)

_CONFIG_PREFIX_SCRIPT = rb"""<script>
(function () {
  var el = document.getElementById("jupyter-config-data");
  if (!el) { return; }
  try {
    var cfg = JSON.parse(el.textContent);
    var appUrl = cfg.appUrl || "";
    var path = window.location.pathname;
    var prefix = path;
    if (appUrl && path.slice(-appUrl.length) === appUrl) {
      prefix = path.slice(0, path.length - appUrl.length);
    }
    if (prefix.slice(-1) !== "/") { prefix += "/"; }
    // "baseUrl" is the one field every other URL in the app is ultimately
    // built from (ServiceManager, ServerConnection, etc. via
    // URLExt.join(baseUrl, <relative *Url field>)) - fixing this one
    // field is sufficient; see the module-level comment above for why
    // the other *Url fields must be left alone.
    if (typeof cfg.baseUrl === "string" && cfg.baseUrl.indexOf("://") === -1) {
      cfg.baseUrl = prefix;
    }
    el.textContent = JSON.stringify(cfg);
  } catch (e) { /* leave jupyter-config-data untouched on any error */ }
})();
</script>"""


def _rewrite(body: bytes) -> bytes:
    body = _HREF_SRC_RE.sub(rb'\1="', body)
    body = _STATIC_STR_RE.sub(rb'"static/', body)
    body = _CONFIG_URL_RE.sub(rb'\1"', body)
    body = _CONFIG_DATA_TAG_RE.sub(rb'\1' + _CONFIG_PREFIX_SCRIPT, body, count=1)
    return body


def _rewrite_location(value: str) -> str:
    """Rewrite a domain-absolute `Location` redirect target to a relative one.

    Mirrors `_rewrite()`'s narrow philosophy: only a single leading "/" (e.g.
    JupyterLab's root route replying `Location: /lab?`) is stripped. "//..."
    (protocol-relative) and "scheme://..." (absolute) values are passed
    through unmodified, since those are not the domain-absolute-path case
    this shim exists to fix (see Issue #76).
    """
    if value.startswith("/") and not value.startswith("//"):
        return value[1:]
    return value


def _is_websocket_upgrade(headers) -> bool:
    connection = headers.get("Connection", "")
    upgrade = headers.get("Upgrade", "")
    return "upgrade" in connection.lower() and upgrade.lower() == "websocket"


def _relay_raw(client_sock: socket.socket, backend_sock: socket.socket) -> None:
    """Bidirectional raw byte relay for WebSocket connections.

    No inspection/rewriting here at all — Jupyter's kernel/terminal traffic
    over WS must pass through byte-for-byte or kernel execution breaks.
    """
    sockets = [client_sock, backend_sock]
    try:
        while True:
            readable, _, exceptional = select.select(sockets, [], sockets, 60)
            if exceptional:
                break
            if not readable:
                continue
            done = False
            for sock in readable:
                other = backend_sock if sock is client_sock else client_sock
                try:
                    data = sock.recv(65536)
                except OSError:
                    done = True
                    break
                if not data:
                    done = True
                    break
                other.sendall(data)
            if done:
                break
    finally:
        for sock in sockets:
            try:
                sock.close()
            except OSError:
                pass


class ShimHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle(self) -> None:
        if _is_websocket_upgrade(self.headers):
            self._proxy_websocket()
            return
        self._proxy_http()

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_PATCH = _handle
    do_DELETE = _handle
    do_HEAD = _handle
    do_OPTIONS = _handle

    def _proxy_websocket(self) -> None:
        try:
            backend_sock = socket.create_connection((BACKEND_HOST, BACKEND_PORT), timeout=10)
        except OSError as exc:
            self.send_error(502, f"upstream connect failed: {exc}")
            return
        # Reconstruct the original request line + headers exactly as received
        # and hand them to the backend before starting the raw duplex relay —
        # the backend needs the real WS handshake headers (Sec-WebSocket-Key
        # etc.) to complete its own half of the upgrade.
        request_line = f"{self.command} {self.path} {self.request_version}\r\n"
        header_lines = "".join(f"{k}: {v}\r\n" for k, v in self.headers.items())
        backend_sock.sendall((request_line + header_lines + "\r\n").encode("latin-1"))
        _relay_raw(self.connection, backend_sock)

    def _proxy_http(self) -> None:
        content_length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(content_length) if content_length else b""

        conn = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=30)
        try:
            forward_headers = {k: v for k, v in self.headers.items() if k.lower() != "host"}
            # Issue #83: jupyter_server's own Cross-Origin API protection (a
            # CSRF-hardening layer independent of the `_xsrf` token check)
            # rejects any state-changing request (POST/PUT/...) whose
            # `Origin` header doesn't match the `Host` it sees on the
            # connection — logged server-side as "Blocking Cross Origin API
            # request", returned to the client as a generic 404 (not 403),
            # which is what made this look like a routing bug rather than a
            # security check at first. The browser's `Origin` is always the
            # real, tile-prefixed page origin (e.g. `http://<coder-host>`),
            # never this backend's own `127.0.0.1:8889` — exactly the same
            # prefix-stripping mismatch already documented throughout this
            # module — so every kernel-session start, notebook save, and
            # workspace-layout save (all POST/PUT) failed even though every
            # GET worked fine (this check doesn't apply to GET). Fixed the
            # same way the `Host` header is already handled two lines
            # above: rewrite the forwarded `Origin` to match the backend
            # this shim actually connects to. Safe to do unconditionally —
            # the backend binds 127.0.0.1 only and this shim is the sole
            # possible caller (see module docstring), so there is no other,
            # real cross-origin request this could be confused with.
            if "origin" in {k.lower() for k in forward_headers}:
                for key in list(forward_headers):
                    if key.lower() == "origin":
                        forward_headers[key] = f"http://{BACKEND_HOST}:{BACKEND_PORT}"
            conn.request(self.command, self.path, body=body, headers=forward_headers)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            self.send_error(502, f"upstream request failed: {exc}")
            return

        resp_body = resp.read()
        content_type = resp.getheader("Content-Type", "")
        if any(content_type.startswith(t) for t in REWRITE_CONTENT_TYPES):
            resp_body = _rewrite(resp_body)

        self.send_response(resp.status, resp.reason)
        for key, value in resp.getheaders():
            if key.lower() in ("content-length", "transfer-encoding", "connection"):
                continue
            if key.lower() == "location":
                value = _rewrite_location(value)
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(resp_body)
        conn.close()

    def log_message(self, fmt, *args):  # noqa: D401 - keep default logging quiet
        sys.stderr.write("jupyter-proxy-shim: " + (fmt % args) + "\n")


def main() -> None:
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ShimHandler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
