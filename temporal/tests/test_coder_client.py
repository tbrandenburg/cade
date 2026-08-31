"""Unit tests for `demo.coder_client.CoderClient` — mocks only the HTTP
transport (via `respx`), never the client code itself."""

import logging

import httpx
import pytest
import respx

from demo.coder_client import CoderAPIError, CoderClient

BASE_URL = "http://coder.test:7080"
TOKEN = "super-secret-token-value"


@pytest.mark.asyncio
async def test_get_workspace_404_returns_none():
    with respx.mock(base_url=BASE_URL) as mock:
        mock.get("/api/v2/users/temporal-svc/workspace/tw-missing").mock(
            return_value=httpx.Response(404, json={"message": "not found"})
        )
        async with CoderClient(BASE_URL, TOKEN) as client:
            result = await client.get_workspace("temporal-svc", "tw-missing")
    assert result is None


@pytest.mark.asyncio
async def test_get_workspace_found_returns_dict():
    with respx.mock(base_url=BASE_URL) as mock:
        mock.get("/api/v2/users/temporal-svc/workspace/tw-exists").mock(
            return_value=httpx.Response(200, json={"id": "abc-123", "name": "tw-exists"})
        )
        async with CoderClient(BASE_URL, TOKEN) as client:
            result = await client.get_workspace("temporal-svc", "tw-exists")
    assert result == {"id": "abc-123", "name": "tw-exists"}


@pytest.mark.asyncio
async def test_requests_use_coder_session_token_header():
    with respx.mock(base_url=BASE_URL) as mock:
        route = mock.get("/api/v2/users/me").mock(
            return_value=httpx.Response(200, json={"id": "u1", "username": "temporal-svc"})
        )
        async with CoderClient(BASE_URL, TOKEN) as client:
            await client.me()
    sent_request = route.calls[0].request
    assert sent_request.headers["Coder-Session-Token"] == TOKEN
    assert "Authorization" not in sent_request.headers


@pytest.mark.asyncio
async def test_error_response_raises_coder_api_error():
    with respx.mock(base_url=BASE_URL) as mock:
        mock.get("/api/v2/organizations").mock(
            return_value=httpx.Response(500, text="internal error")
        )
        async with CoderClient(BASE_URL, TOKEN) as client:
            with pytest.raises(CoderAPIError):
                await client.default_organization_id()


@pytest.mark.asyncio
async def test_token_never_appears_in_logs(caplog):
    """HARD requirement from the issue: the token must never appear in
    any log line, exception message, or __repr__."""
    caplog.set_level(logging.DEBUG)
    with respx.mock(base_url=BASE_URL) as mock:
        mock.get("/api/v2/organizations").mock(
            return_value=httpx.Response(403, text="forbidden: bad credentials")
        )
        async with CoderClient(BASE_URL, TOKEN) as client:
            repr_str = repr(client)
            assert TOKEN not in repr_str
            with pytest.raises(CoderAPIError) as exc_info:
                await client.default_organization_id()
            assert TOKEN not in str(exc_info.value)

    for record in caplog.records:
        assert TOKEN not in record.getMessage()


@pytest.mark.asyncio
async def test_create_workspace_posts_expected_body():
    with respx.mock(base_url=BASE_URL) as mock:
        route = mock.post(
            "/api/v2/organizations/org-1/members/temporal-svc/workspaces"
        ).mock(return_value=httpx.Response(201, json={"id": "ws-1", "name": "tw-new"}))
        async with CoderClient(BASE_URL, TOKEN) as client:
            result = await client.create_workspace(
                "org-1",
                "temporal-svc",
                "tw-new",
                "version-1",
                [{"name": "github_token", "value": ""}],
            )
    assert result == {"id": "ws-1", "name": "tw-new"}
    body = route.calls[0].request.content
    assert b"version-1" in body
    assert b"tw-new" in body
