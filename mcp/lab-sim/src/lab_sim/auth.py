"""Bearer-token authentication for the M11 Lab Simulator MCP/HTTP service.

Per the MCP spec's "Local MCP Server Compromise" guidance, an MCP service
exposed over HTTP (rather than `stdio`) must require a bearer token - never
an open, unauthenticated TCP port. This module also resolves *which*
authenticated caller made the request, so tool handlers can bind
`reserve_device()`'s returned reservation ID to that caller server-side (the
MCP spec's "State Handle Hijacking" guidance): the reservation ID alone must
never be treated as sufficient authorization for `run_test()`/`get_logs()`/
`release_device()`.

Tokens are configured via the `LAB_SIM_TOKENS` environment variable, a
comma-separated list of `caller_id:token` pairs, e.g.
`LAB_SIM_TOKENS="agent-a:tok-aaa,agent-b:tok-bbb"`. This is a simple static
credential store appropriate for a local, single-operator lab simulator -
not a substitute for the OAuth-based `mcp.server.auth` flow a
multi-tenant/production deployment would need.
"""

from __future__ import annotations

import hmac
import os


def _load_tokens() -> dict[str, str]:
    """Parse LAB_SIM_TOKENS into {caller_id: token}."""
    raw = os.environ.get("LAB_SIM_TOKENS", "")
    tokens: dict[str, str] = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if not pair or ":" not in pair:
            continue
        caller_id, token = pair.split(":", 1)
        caller_id = caller_id.strip()
        token = token.strip()
        if caller_id and token:
            tokens[caller_id] = token
    return tokens


TOKENS: dict[str, str] = _load_tokens()


def caller_for_token(token: str) -> str | None:
    """Return the caller_id bound to `token`, or None if the token is
    unknown. Uses constant-time comparison to avoid timing side-channels."""
    for caller_id, known_token in TOKENS.items():
        if hmac.compare_digest(known_token, token):
            return caller_id
    return None


def caller_for_authorization_header(value: str | None) -> str | None:
    """Extract and resolve the caller_id from a raw `Authorization` header
    value (`"Bearer <token>"`). Returns None if missing, malformed, or the
    token is unknown."""
    if not value or not value.lower().startswith("bearer "):
        return None
    token = value[len("Bearer ") :].strip()
    if not token:
        return None
    return caller_for_token(token)
