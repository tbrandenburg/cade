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
# Intentionally does NOT touch "//" (protocol-relative URLs), query strings,
# or any occurrence not immediately following one of these exact markers —
# this avoids corrupting WebSocket URLs (ws://...), JSON payloads, or
# unrelated strings that merely contain a "/" character.
_HREF_SRC_RE = re.compile(rb'(href|src)="/(?!/)')
_STATIC_STR_RE = re.compile(rb'"/static/')


def _rewrite(body: bytes) -> bytes:
    body = _HREF_SRC_RE.sub(rb'\1="', body)
    body = _STATIC_STR_RE.sub(rb'"static/', body)
    return body


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
