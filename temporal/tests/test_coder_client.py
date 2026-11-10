"""Tests for `demo.coder_client.CoderClient` with mocked and loopback HTTP."""

import asyncio
import logging

import httpx
import pytest
import respx
from demo.coder_client import CoderAPIError, CoderClient

BASE_URL = "http://coder.test:7080"
TOKEN = "super-secret-token-value"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("operation", "path"),
    [
        ("me", "/api/v2/users/me"),
        ("workspace", "/api/v2/users/temporal-svc/workspace/tw-test"),
    ],
)
async def test_loopback_error_does_not_expose_response(operation, path, caplog):
    received = []
    body_marker = "untrusted-response-body"

    async def respond(reader, writer):
        request = await reader.readuntil(b"\r\n\r\n")
        received.append(request)
        token = next(
            line.split(b":", 1)[1].strip()
            for line in request.split(b"\r\n")
            if line.lower().startswith(b"coder-session-token:")
        )
        body = body_marker.encode() + b": " + token
        writer.write(
            b"HTTP/1.1 401 Unauthorized\r\nContent-Length: "
            + str(len(body)).encode()
            + b"\r\nConnection: close\r\n\r\n"
            + body
        )
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    server = await asyncio.start_server(respond, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    caplog.set_level(logging.DEBUG)
    try:
        async with CoderClient(f"http://127.0.0.1:{port}", TOKEN) as client:
            with pytest.raises(CoderAPIError) as exc_info:
                if operation == "me":
                    await client.me()
                else:
                    await client.get_workspace("temporal-svc", "tw-test")
    finally:
        server.close()
        await server.wait_closed()

    assert len(received) == 1
    assert f"GET {path} HTTP/1.1".encode() in received[0]
    assert f"Coder-Session-Token: {TOKEN}".lower().encode() in received[0].lower()
    assert exc_info.value.status_code == 401
    assert f"GET {path} -> 401" in str(exc_info.value)
    if operation == "me":
        assert f"coder_client: GET {path} -> 401" in caplog.text
    for output in (str(exc_info.value), caplog.text):
        assert TOKEN not in output
        assert body_marker not in output


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
            return_value=httpx.Response(
                200, json={"id": "abc-123", "name": "tw-exists"}
            )
        )
        async with CoderClient(BASE_URL, TOKEN) as client:
            result = await client.get_workspace("temporal-svc", "tw-exists")
    assert result == {"id": "abc-123", "name": "tw-exists"}


@pytest.mark.asyncio
async def test_requests_use_coder_session_token_header():
    with respx.mock(base_url=BASE_URL) as mock:
        route = mock.get("/api/v2/users/me").mock(
            return_value=httpx.Response(
                200, json={"id": "u1", "username": "temporal-svc"}
            )
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
async def test_empty_organizations_keeps_local_explanation():
    with respx.mock(base_url=BASE_URL) as mock:
        mock.get("/api/v2/organizations").mock(
            return_value=httpx.Response(200, json=[])
        )
        async with CoderClient(BASE_URL, TOKEN) as client:
            with pytest.raises(CoderAPIError) as exc_info:
                await client.default_organization_id()
    assert exc_info.value.status_code == 200
    assert "no organizations returned" in str(exc_info.value)


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
