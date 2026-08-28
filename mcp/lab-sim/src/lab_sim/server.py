"""M11 MCP/HTTP Service 2 - Lab Simulator.

Exposes `list_devices`, `reserve_device`, `flash_device`, `run_test`,
`get_logs`, `release_device` against simulated devices (`devices.py`), over
`streamable-http` transport. Every request must carry a valid
`Authorization: Bearer <token>` header (`auth.py`) - enforced twice, by
design:

1. `BearerAuthMiddleware`, at the ASGI layer, rejects any request without a
   recognized token before it reaches the MCP session/tool dispatch at all
   (401, per the MCP spec's "Local MCP Server Compromise" guidance - no
   open, unauthenticated port).
2. Each tool independently re-resolves the caller from the same header via
   `ctx.headers` and passes it into `LabSimulator`, which binds
   `reserve_device()`'s reservation ID to that caller and rejects any later
   call presenting a different caller (the "State Handle Hijacking"
   guidance) - the reservation ID by itself is never sufficient
   authorization.

Milestone M12 (Governance Foundation) adds a third layer for the two
privileged actions (`flash_device`, `run_test`): both query OPA's live
decision API (`lab_sim.policy.check_allowed`) before touching device state.
The allow/deny logic itself lives entirely in `governance/opa/policy/
lab_authz.rego`, not here - this module never encodes the `approved==true`
requirement for `flash_device` directly, it only forwards the decision.
"""

from __future__ import annotations

import contextlib
import logging

from mcp.server.mcpserver import Context, MCPServer
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from lab_sim import devices
from lab_sim.auth import caller_for_authorization_header
from lab_sim.policy import check_allowed

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("lab_sim.server")

mcp = MCPServer("devenv-cloud-lab-sim")


def _authenticated_caller(ctx: Context) -> str:
    """Resolve the authenticated caller_id for the current tool call, or
    raise PermissionError. Tool handlers below must call this before
    touching any reservation-scoped state."""
    headers = ctx.headers or {}
    caller_id = caller_for_authorization_header(headers.get("authorization"))
    if caller_id is None:
        raise PermissionError("missing or invalid bearer token")
    return caller_id


@mcp.tool()
def list_devices() -> list[dict[str, str]]:
    """List simulated devices and their current status. Does not require
    ownership of any reservation (read-only fleet inventory)."""
    return devices.SIMULATOR.list_devices()


@mcp.tool()
def reserve_device(device_id: str, ctx: Context) -> dict[str, str]:
    """Reserve an available simulated device. Returns a reservation_id bound
    server-side to the authenticated caller; only that caller may use it in
    subsequent flash_device/run_test/get_logs/release_device calls."""
    caller_id = _authenticated_caller(ctx)
    reservation_id = devices.SIMULATOR.reserve_device(device_id, caller_id)
    logger.info("reserve_device: caller=%s device=%s reservation=%s", caller_id, device_id, reservation_id)
    return {"reservation_id": reservation_id, "device": device_id}


@mcp.tool()
def flash_device(reservation_id: str, ctx: Context, approved: bool = False) -> str:
    """Flash the reserved device with a simulated firmware image. Requires
    the caller to own `reservation_id` AND a live ALLOW decision from OPA's
    `lab.authz` policy for `flash_device` - denied unless `approved=True`
    (human/workflow sign-off), per the M12 governance policy. Raises
    `PolicyDenied` (surfaced as a tool error) otherwise."""
    caller_id = _authenticated_caller(ctx)
    check_allowed("flash_device", approved=approved)
    result = devices.SIMULATOR.flash_device(reservation_id, caller_id)
    logger.info("flash_device: caller=%s reservation=%s approved=%s", caller_id, reservation_id, approved)
    return result


@mcp.tool()
def run_test(reservation_id: str, ctx: Context) -> dict[str, str]:
    """Run the approved simulated test operation against the reserved
    device. Requires the caller to own `reservation_id` AND a live ALLOW
    decision from OPA's `lab.authz` policy for `run_test` (always allowed
    per the current policy, but the decision is still queried live, never
    hardcoded)."""
    caller_id = _authenticated_caller(ctx)
    check_allowed("run_test")
    result = devices.SIMULATOR.run_test(reservation_id, caller_id)
    logger.info("run_test: caller=%s reservation=%s result=%s", caller_id, reservation_id, result)
    return result


@mcp.tool()
def get_logs(reservation_id: str, ctx: Context) -> list[str]:
    """Retrieve the log lines recorded for `reservation_id`. Requires the
    caller to own the reservation."""
    caller_id = _authenticated_caller(ctx)
    logs = devices.SIMULATOR.get_logs(reservation_id, caller_id)
    logger.info("get_logs: caller=%s reservation=%s lines=%d", caller_id, reservation_id, len(logs))
    return logs


@mcp.tool()
def release_device(reservation_id: str, ctx: Context) -> str:
    """Release a reserved device back to `available`. Requires the caller to
    own `reservation_id`."""
    caller_id = _authenticated_caller(ctx)
    result = devices.SIMULATOR.release_device(reservation_id, caller_id)
    logger.info("release_device: caller=%s reservation=%s", caller_id, reservation_id)
    return result


class BearerAuthMiddleware:
    """ASGI middleware: reject any HTTP request without a recognized
    `Authorization: Bearer <token>` header before it reaches the MCP session
    layer. Non-HTTP scopes (e.g. lifespan) pass through unchanged."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        raw_headers = dict(scope.get("headers", []))
        auth_value = raw_headers.get(b"authorization", b"").decode("latin-1")
        if caller_for_authorization_header(auth_value) is None:
            response = JSONResponse({"error": "unauthorized"}, status_code=401)
            await response(scope, receive, send)
            return
        await self.app(scope, receive, send)


def build_app() -> Starlette:
    """Mount the MCP streamable-http app at `/mcp`. `BearerAuthMiddleware`
    wraps the whole ASGI app (below, not just this Mount) so the 401
    short-circuit happens before Starlette's own routing runs."""
    from starlette.routing import Mount

    mcp_app = mcp.streamable_http_app(streamable_http_path="/", json_response=True)

    @contextlib.asynccontextmanager
    async def lifespan(_app: Starlette):
        async with mcp.session_manager.run():
            yield

    return Starlette(routes=[Mount("/mcp", app=mcp_app)], lifespan=lifespan)


app = BearerAuthMiddleware(build_app())


def main() -> None:
    import os

    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("LAB_SIM_PORT", "8300")))


if __name__ == "__main__":
    main()
