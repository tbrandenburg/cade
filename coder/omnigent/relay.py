"""Expose only policy and context operations from the unsandboxed native relay."""

import http.client
import json
import os
import socketserver
import sys
from http.server import BaseHTTPRequestHandler
from pathlib import Path

CONTEXT_TOOLS = frozenset({"list_comments", "sys_list_models", "load_skill"})


class Relay(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def __init__(self, path: str, port: int) -> None:
        self.port = port
        super().__init__(path, Handler)


class Handler(BaseHTTPRequestHandler):
    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(30)

    def log_message(self, *_args: object) -> None:
        return

    def respond(self, payload: object) -> None:
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path not in {"/policies/evaluate", "/tool"}:
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 1048576:
                raise ValueError("invalid request size")
            body = self.rfile.read(length)
            payload = json.loads(body)
            if not isinstance(payload, dict):
                raise TypeError("invalid request body")
        except (TypeError, ValueError, OSError):
            self.send_error(400)
            return
        name = payload.get("name")
        if self.path == "/tool" and (
            not isinstance(name, str) or name not in CONTEXT_TOOLS
        ):
            self.respond(
                {
                    "isError": True,
                    "content": [
                        {
                            "type": "text",
                            "text": "CADE denies outside-runner actions; use SRT-confined native tools.",
                        }
                    ],
                }
            )
            return
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.port, timeout=30
        )
        try:
            connection.request(
                "POST",
                self.path,
                body=body,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": self.headers.get("Authorization", ""),
                },
            )
            response = connection.getresponse()
            data = response.read(1048577)
            if response.status != 200 or len(data) > 1048576:
                raise ValueError("native relay rejected request")
            self.respond(json.loads(data))
        except (OSError, ValueError, http.client.HTTPException):
            if self.path == "/policies/evaluate":
                self.respond(
                    {
                        "result": "POLICY_ACTION_DENY",
                        "reason": "policy relay unavailable",
                    }
                )
                return
            self.respond(
                {
                    "isError": True,
                    "content": [{"type": "text", "text": "native relay unavailable"}],
                }
            )
        finally:
            connection.close()


if __name__ == "__main__":
    port = int(sys.argv[1])
    if port not in range(28700, 28716):
        raise ValueError("unsupported native relay port")
    path = Path(f"/tmp/cade-omnigent-{os.getuid()}/relay-{port}.sock")
    path.unlink(missing_ok=True)
    server = Relay(str(path), port)
    path.chmod(0o600)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        path.unlink(missing_ok=True)
