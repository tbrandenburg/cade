"""Thin MCP client for the M11 lab-sim service, used by the M15 end-to-end
Activities (`e2e_activities.py`) to call `reserve_device`/`run_test`/
`get_logs`/`release_device` over `streamable-http` — the same MCP round
trip `scripts/verify-governance.sh` exercises manually, just invoked from
inside a Temporal Activity instead of a one-off script.

A fresh MCP session is opened and closed per call: Activities are meant to
be small, retryable, idempotent units of work (see `activities.py`'s
idempotency-key pattern), not long-lived session holders — a Temporal
worker crash between Activities must not leave a dangling MCP session.
"""

from __future__ import annotations

import json
from typing import Any

import httpx2
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from demo.config import LAB_SIM_AGENT_TOKEN, LAB_SIM_URL


async def _call_tool(tool: str, arguments: dict[str, Any]) -> Any:
    client = httpx2.AsyncClient(
        headers={"Authorization": f"Bearer {LAB_SIM_AGENT_TOKEN}"}
    )
    async with streamable_http_client(LAB_SIM_URL, http_client=client) as (
        read,
        write,
    ):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool, arguments)
            if result.is_error:
                raise RuntimeError(
                    f"lab-sim tool '{tool}' returned an error: "
                    f"{result.content[0].text if result.content else '<no detail>'}"
                )
            if not result.content:
                return None
            if len(result.content) > 1:
                # A tool returning a list surfaces one text content block
                # per list item. `list_devices` (M12's
                # scripts/verify-governance.sh) emits JSON-object items;
                # `get_logs` emits plain-string log lines - decode each
                # item independently, falling back to the raw text.
                items = []
                for c in result.content:
                    try:
                        items.append(json.loads(c.text))
                    except json.JSONDecodeError:
                        items.append(c.text)
                return items
            text = result.content[0].text
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                # Plain-string tool results (e.g. release_device/
                # flash_device return a bare status string, not a
                # JSON-encoded value) - pass the text through unparsed.
                return text


async def reserve_device(device_id: str) -> dict[str, str]:
    return await _call_tool("reserve_device", {"device_id": device_id})


async def run_test(reservation_id: str) -> dict[str, str]:
    return await _call_tool("run_test", {"reservation_id": reservation_id})


async def get_logs(reservation_id: str) -> list[str]:
    return await _call_tool("get_logs", {"reservation_id": reservation_id})


async def release_device(reservation_id: str) -> str:
    return await _call_tool("release_device", {"reservation_id": reservation_id})
