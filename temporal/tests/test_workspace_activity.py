"""Unit tests for `demo.workspace_activity` — name validation, container-
name derivation, and the empty-token fail-closed path. No live Coder
server needed; the empty-token path is exercised by monkeypatching the
module's config import (the real fail-closed behavior, not a reimplementation
of it)."""

import pytest

from demo import workspace_activity
from demo.workspace_activity import (
    DEFAULT_RICH_PARAMETER_VALUES,
    container_name_for,
    ensure_coder_workspace,
    reap_coder_workspaces,
    validate_workspace_name,
)


def test_validate_workspace_name_accepts_valid_name():
    assert validate_workspace_name("tw-issue50-demo") is None


def test_validate_workspace_name_rejects_bad_chars():
    error = validate_workspace_name("tw-Has_Upper_And_Underscore")
    assert error is not None


def test_validate_workspace_name_rejects_missing_prefix():
    error = validate_workspace_name("not-prefixed")
    assert error is not None


def test_validate_workspace_name_rejects_over_32_chars():
    long_name = "tw-" + ("a" * 30)  # 33 chars total
    assert len(long_name) > 32
    error = validate_workspace_name(long_name)
    assert error is not None
    assert "32-char cap" in error


def test_default_rich_parameter_values_sets_temporal_owned_true():
    # Regression guard for Issue #55: this Activity only ever creates
    # Temporal-owned tw-* workspaces, so DEFAULT_RICH_PARAMETER_VALUES must
    # always include an entry rendering the Temporal Workflows dashboard
    # tile (coder_app.temporal in coder/templates/docker-workspace/main.tf).
    # If a future refactor drops this entry, the tile silently stops
    # appearing for workspaces created via this path.
    matches = [
        entry
        for entry in DEFAULT_RICH_PARAMETER_VALUES
        if entry["name"] == "temporal_owned"
    ]
    assert len(matches) == 1
    assert matches[0]["value"] == "true"


def test_container_name_for_matches_issue_49_convention():
    # Byte-for-byte the same convention verified live in Issue #49.
    assert container_name_for("issue45verify", "Issue49Verify") == "coder-issue45verify-issue49verify"


@pytest.mark.asyncio
async def test_ensure_coder_workspace_fails_closed_without_token(monkeypatch):
    monkeypatch.setattr(workspace_activity, "CODER_WORKSPACE_API_TOKEN", "")
    result = await ensure_coder_workspace("tw-no-token")
    assert result["ok"] is False
    assert result["error"] == "coder token not configured"
    assert result["workspace_id"] is None
    assert result["container_name"] is None


@pytest.mark.asyncio
async def test_ensure_coder_workspace_fails_closed_on_bad_name(monkeypatch):
    monkeypatch.setattr(workspace_activity, "CODER_WORKSPACE_API_TOKEN", "some-token")
    result = await ensure_coder_workspace("invalid name!")
    assert result["ok"] is False
    assert "must match" in result["error"] or "32-char cap" in result["error"]


@pytest.mark.asyncio
async def test_reap_coder_workspaces_fails_closed_without_token(monkeypatch):
    monkeypatch.setattr(workspace_activity, "CODER_WORKSPACE_API_TOKEN", "")
    result = await reap_coder_workspaces()
    assert result["inspected"] == 0
    assert result["reaped"] == []
    assert result["error"] == "coder token not configured"
