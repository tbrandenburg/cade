"""Issue #50: thin async HTTP client for the Coder API, used by
`workspace_activity.py` to resolve-or-create a Temporal-owned Coder
workspace on demand (Phase 2 of #49's persistent-workspace work).

HARD requirement (see the issue body and AGENTS.md's two recorded
token-leak incidents for `scripts/ai-token.sh`): the session token must
never appear in any log line, exception message, or `__repr__`. Every
place this module logs or raises includes only `_redact()`'d values, and
`CoderClient.__repr__` never includes the raw token.

Coder REST API shapes referenced here (verified against Coder v2.36.3's
own OpenAPI-documented behavior, not guessed):
  - Auth header: `Coder-Session-Token: <token>` (NOT `Authorization:
    Bearer ...`).
  - `GET /api/v2/users/{user}/workspace/{workspace_name}` -> 200 with the
    workspace object, or 404 if it doesn't exist.
  - `GET /api/v2/organizations` -> list; used to resolve the default org.
  - `GET /api/v2/organizations/{org_id}/templates/{template_name}` ->
    template object with `active_version_id`.
  - `POST /api/v2/organizations/{org_id}/members/{user}/workspaces` ->
    create a workspace from a template version + rich parameter values.
  - `GET /api/v2/workspaces/{id}` -> poll `latest_build.status`.
  - `POST /api/v2/workspaces/{id}/builds` with `{"transition": "start"|
    "stop"|"delete"}` -> start/stop/delete a workspace.
  - `GET /api/v2/workspaces?q=owner:<owner>` -> list a single user's
    workspaces (scoped, avoids scanning every workspace on the server -
    see the issue's `temporal-svc` ownership-marker rationale; verified
    live that the issue's originally-assumed
    `GET /api/v2/users/{owner}/workspaces` does not exist on v2.36.3 -
    405 Method Not Allowed).
"""

from __future__ import annotations

import logging

import httpx

logger = logging.getLogger("demo.coder_client")

SESSION_TOKEN_HEADER = "Coder-Session-Token"


def _redact(value: str | None) -> str:
    """Never log/print a raw secret. Used for any value that might be, or
    might contain, the session token before it reaches a log line."""
    if not value:
        return "<empty>"
    return "<redacted>"


class CoderAPIError(RuntimeError):
    """Raised for a non-2xx/404 Coder API response. Deliberately never
    includes the request's Authorization header (httpx exceptions can
    otherwise echo full request details) - only status code and a
    truncated, token-free response body snippet."""

    def __init__(self, method: str, url: str, status_code: int, body_snippet: str):
        super().__init__(
            f"Coder API error: {method} {url} -> {status_code}: {body_snippet}"
        )
        self.status_code = status_code


class CoderClient:
    """Minimal async client for exactly the endpoints
    `workspace_activity.py` needs. Not a general-purpose Coder SDK."""

    def __init__(self, base_url: str, token: str, timeout: float = 30.0) -> None:
        self._base_url = base_url.rstrip("/")
        self._token = token
        self._client = httpx.AsyncClient(
            base_url=self._base_url,
            headers={SESSION_TOKEN_HEADER: token},
            timeout=timeout,
        )

    def __repr__(self) -> str:  # noqa: D105 - never leak the token
        return f"CoderClient(base_url={self._base_url!r}, token=<redacted>)"

    async def aclose(self) -> None:
        await self._client.aclose()

    async def __aenter__(self) -> "CoderClient":
        return self

    async def __aexit__(self, *exc_info: object) -> None:
        await self.aclose()

    async def _request(self, method: str, path: str, **kwargs: object) -> httpx.Response:
        response = await self._client.request(method, path, **kwargs)
        if response.status_code >= 400:
            # Truncate and never assume the body is token-free noise -
            # but the token itself is never echoed by the Coder API in a
            # response body, so a length-capped snippet is safe here.
            snippet = response.text[:500]
            logger.warning(
                "coder_client: %s %s -> %s: %s", method, path, response.status_code, snippet
            )
            raise CoderAPIError(method, path, response.status_code, snippet)
        return response

    async def me(self) -> dict:
        response = await self._request("GET", "/api/v2/users/me")
        return response.json()

    async def get_workspace(self, owner: str, name: str) -> dict | None:
        """Resolve a workspace by owner+name. Returns None on 404 (does
        not exist yet) rather than raising, matching the issue's
        resolve-or-create contract."""
        try:
            response = await self._client.get(
                f"/api/v2/users/{owner}/workspace/{name}"
            )
        except httpx.HTTPError as exc:
            raise CoderAPIError("GET", f"/api/v2/users/{owner}/workspace/{name}", 0, str(exc)) from exc
        if response.status_code == 404:
            return None
        if response.status_code >= 400:
            snippet = response.text[:500]
            raise CoderAPIError("GET", f"/api/v2/users/{owner}/workspace/{name}", response.status_code, snippet)
        return response.json()

    async def get_workspace_by_id(self, workspace_id: str) -> dict:
        response = await self._request("GET", f"/api/v2/workspaces/{workspace_id}")
        return response.json()

    async def list_workspaces(self, owner: str) -> list[dict]:
        # NOTE: `GET /api/v2/users/{owner}/workspaces` (the issue's own
        # draft plan) does not exist on Coder v2.36.3 (`405 Method Not
        # Allowed`, verified live) — the real scoped-listing endpoint is
        # `GET /api/v2/workspaces?q=owner:<owner>`, using the same query
        # filter syntax as the Coder Web UI's workspace search.
        response = await self._request(
            "GET", "/api/v2/workspaces", params={"q": f"owner:{owner}"}
        )
        return response.json().get("workspaces", [])

    async def default_organization_id(self) -> str:
        response = await self._request("GET", "/api/v2/organizations")
        orgs = response.json()
        if not orgs:
            raise CoderAPIError("GET", "/api/v2/organizations", 200, "no organizations returned")
        for org in orgs:
            if org.get("is_default"):
                return org["id"]
        return orgs[0]["id"]

    async def template_version_id(self, org_id: str, template_name: str) -> str:
        response = await self._request(
            "GET", f"/api/v2/organizations/{org_id}/templates/{template_name}"
        )
        template = response.json()
        return template["active_version_id"]

    async def create_workspace(
        self,
        org_id: str,
        owner: str,
        name: str,
        template_version_id: str,
        rich_parameter_values: list[dict],
    ) -> dict:
        response = await self._request(
            "POST",
            f"/api/v2/organizations/{org_id}/members/{owner}/workspaces",
            json={
                "name": name,
                "template_version_id": template_version_id,
                "rich_parameter_values": rich_parameter_values,
                "automatic_updates": "never",
            },
        )
        return response.json()

    async def start_workspace(self, workspace_id: str) -> dict:
        response = await self._request(
            "POST",
            f"/api/v2/workspaces/{workspace_id}/builds",
            json={"transition": "start"},
        )
        return response.json()

    async def stop_workspace(self, workspace_id: str) -> dict:
        response = await self._request(
            "POST",
            f"/api/v2/workspaces/{workspace_id}/builds",
            json={"transition": "stop"},
        )
        return response.json()

    async def delete_workspace(self, workspace_id: str) -> dict:
        response = await self._request(
            "POST",
            f"/api/v2/workspaces/{workspace_id}/builds",
            json={"transition": "delete"},
        )
        return response.json()
