"""M12 Governance Foundation - OPA decision-API client for the M11 Lab
Simulator.

Per the step file's requirement, allow/deny logic for privileged actions
(`flash_device`, `run_test`) must live in the `lab.authz` Rego policy
(`governance/opa/policy/lab_authz.rego`), evaluated live via OPA's decision
API - never hardcoded in this MCP server. `OPA_URL` defaults to the
in-compose service hostname (`http://opa:8181`), matching the `opa` service
in `compose.yaml`; override for local/out-of-container testing.
"""

from __future__ import annotations

import os

import httpx

OPA_URL = os.environ.get("OPA_URL", "http://opa:8181")
DECISION_PATH = "/v1/data/lab/authz/allow"


class PolicyDenied(PermissionError):
    """Raised when OPA's decision API returns `allow: false` (or is
    unreachable - fail closed, never fail open on a privileged action)."""


def check_allowed(action: str, **extra: object) -> None:
    """Query OPA's decision API for `action`. Raises `PolicyDenied` unless
    the response is exactly `{"result": true}`. Fails closed: any transport
    error, timeout, or non-boolean-true result is treated as a denial."""
    payload = {"input": {"action": action, **extra}}
    try:
        response = httpx.post(f"{OPA_URL}{DECISION_PATH}", json=payload, timeout=5.0)
        response.raise_for_status()
        result = response.json().get("result")
    except httpx.HTTPError as exc:
        raise PolicyDenied(f"OPA decision API unreachable for action={action!r}: {exc}") from exc
    if result is not True:
        raise PolicyDenied(f"OPA denied action={action!r} (approved={extra.get('approved')})")
