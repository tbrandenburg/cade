#!/usr/bin/env bash
# M12 Governance Foundation validation. Runs:
#   1. `opa test` against governance/opa/policy (regression pins).
#   2. A live query against OPA's decision API for `run_test` (ALLOW) and
#      `flash_device` without approval (DENY) - not a policy-file review.
#   3. A full round trip through the actual M11 lab-sim MCP tools
#      (reserve -> run_test -> flash_device denied -> flash_device allowed
#      -> release), proving the MCP server's live wiring to OPA, not just
#      the policy in isolation.
#
# Requires: `docker compose up -d opa lab-sim` already running, and
# mcp/lab-sim's uv-managed venv (`uv sync` in mcp/lab-sim) for step 3's
# Python MCP client.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "==> [0/3] Reloading live OPA server with current policy files"
"${REPO_ROOT}/scripts/reload-opa-policy.sh"

echo ""
echo "==> [1/3] opa test governance/opa/policy"
docker run --rm -v "${REPO_ROOT}/governance/opa/policy:/policy:ro" openpolicyagent/opa:1.9.0 test /policy

echo ""
echo "==> [2/3] Live OPA decision API checks"
RUN_TEST_DECISION=$(curl -s -X POST http://127.0.0.1:8181/v1/data/lab/authz/allow \
	-d '{"input":{"action":"run_test"}}')
echo "    run_test -> ${RUN_TEST_DECISION}"
echo "${RUN_TEST_DECISION}" | grep -q '"result":true' || {
	echo "FAIL: expected run_test to be ALLOWed" >&2
	exit 1
}

FLASH_DENY_DECISION=$(curl -s -X POST http://127.0.0.1:8181/v1/data/lab/authz/allow \
	-d '{"input":{"action":"flash_device","approved":false}}')
echo "    flash_device (unapproved) -> ${FLASH_DENY_DECISION}"
echo "${FLASH_DENY_DECISION}" | grep -q '"result":false' || {
	echo "FAIL: expected unapproved flash_device to be DENIED" >&2
	exit 1
}

# Issue #54: workspace.authz round trip (Temporal-owned tw-* Coder
# workspace create/start/stop/delete gate).
WS_CREATE_ALLOW=$(curl -s -X POST http://127.0.0.1:8181/v1/data/workspace/authz/allow \
	-d '{"input":{"action":"create","workspace_name":"tw-demo","owner":"temporal-svc"}}')
echo "    workspace create (valid temporal-svc + tw-*) -> ${WS_CREATE_ALLOW}"
echo "${WS_CREATE_ALLOW}" | grep -q '"result":true' || {
	echo "FAIL: expected valid temporal-svc create of tw-demo to be ALLOWed" >&2
	exit 1
}

WS_CREATE_DENY_OWNER=$(curl -s -X POST http://127.0.0.1:8181/v1/data/workspace/authz/allow \
	-d '{"input":{"action":"create","workspace_name":"tw-demo","owner":"some-other-user"}}')
echo "    workspace create (wrong owner) -> ${WS_CREATE_DENY_OWNER}"
echo "${WS_CREATE_DENY_OWNER}" | grep -q '"result":false' || {
	echo "FAIL: expected wrong-owner create to be DENIED" >&2
	exit 1
}

WS_CREATE_DENY_NAME=$(curl -s -X POST http://127.0.0.1:8181/v1/data/workspace/authz/allow \
	-d '{"input":{"action":"create","workspace_name":"not-tw-prefixed","owner":"temporal-svc"}}')
echo "    workspace create (malformed name) -> ${WS_CREATE_DENY_NAME}"
echo "${WS_CREATE_DENY_NAME}" | grep -q '"result":false' || {
	echo "FAIL: expected malformed-name create to be DENIED" >&2
	exit 1
}

WS_STOP_ALLOW=$(curl -s -X POST http://127.0.0.1:8181/v1/data/workspace/authz/allow \
	-d '{"input":{"action":"stop","workspace_name":"tw-demo","owner":"temporal-svc"}}')
echo "    workspace stop (temporal-svc) -> ${WS_STOP_ALLOW}"
echo "${WS_STOP_ALLOW}" | grep -q '"result":true' || {
	echo "FAIL: expected temporal-svc stop to be ALLOWed" >&2
	exit 1
}

WS_DELETE_ALLOW=$(curl -s -X POST http://127.0.0.1:8181/v1/data/workspace/authz/allow \
	-d '{"input":{"action":"delete","workspace_name":"tw-demo","owner":"temporal-svc","reap_action":"delete"}}')
echo "    workspace delete (reap_action=delete) -> ${WS_DELETE_ALLOW}"
echo "${WS_DELETE_ALLOW}" | grep -q '"result":true' || {
	echo "FAIL: expected delete with reap_action=delete to be ALLOWed" >&2
	exit 1
}

WS_DELETE_DENY=$(curl -s -X POST http://127.0.0.1:8181/v1/data/workspace/authz/allow \
	-d '{"input":{"action":"delete","workspace_name":"tw-demo","owner":"temporal-svc","reap_action":"stop"}}')
echo "    workspace delete (reap_action=stop) -> ${WS_DELETE_DENY}"
echo "${WS_DELETE_DENY}" | grep -q '"result":false' || {
	echo "FAIL: expected delete with reap_action!=delete to be DENIED" >&2
	exit 1
}

echo ""
echo "==> [3/3] Live MCP round trip through lab-sim (reserve -> run_test -> flash_device x2 -> release)"
(
	cd mcp/lab-sim
	source .venv/bin/activate
	python3 - <<'PY'
import asyncio
import json
import sys

import httpx2
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


async def main() -> None:
    client = httpx2.AsyncClient(headers={"Authorization": "Bearer change-me-a"})
    async with streamable_http_client("http://127.0.0.1:8300/mcp/", http_client=client) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            devices = json.loads(f"[{','.join(c.text for c in (await session.call_tool('list_devices', {})).content)}]")
            available = next(d["device"] for d in devices if d["status"] == "available")

            reserve = await session.call_tool("reserve_device", {"device_id": available})
            reservation_id = json.loads(reserve.content[0].text)["reservation_id"]
            print(f"    reserved {available} -> {reservation_id}")

            run_test = await session.call_tool("run_test", {"reservation_id": reservation_id})
            print(f"    run_test: is_error={run_test.is_error} {run_test.content[0].text!r}")
            assert not run_test.is_error, "run_test must be ALLOWed by OPA"

            flash_deny = await session.call_tool("flash_device", {"reservation_id": reservation_id})
            print(f"    flash_device (unapproved): is_error={flash_deny.is_error} {flash_deny.content[0].text!r}")
            assert flash_deny.is_error, "unapproved flash_device must be DENIED by OPA"

            flash_allow = await session.call_tool(
                "flash_device", {"reservation_id": reservation_id, "approved": True}
            )
            print(f"    flash_device (approved): is_error={flash_allow.is_error} {flash_allow.content[0].text!r}")
            assert not flash_allow.is_error, "approved flash_device must be ALLOWed by OPA"

            await session.call_tool("release_device", {"reservation_id": reservation_id})
            print(f"    released {available}")


asyncio.run(main())
print("MCP round trip OK")
PY
)

echo ""
echo "=================================================================="
echo "M12 governance validation PASSED: opa test, live OPA decision API,"
echo "and a live MCP tool round trip all confirm run_test=ALLOW and"
echo "flash_device(unapproved)=DENY / flash_device(approved)=ALLOW."
echo "=================================================================="
