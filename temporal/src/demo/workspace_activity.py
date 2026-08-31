"""Issue #50 Activities: Temporal-owned persistent Coder workspaces.

`ensure_coder_workspace` resolves (or creates, then polls until running) a
Coder workspace entirely through the Coder API — no manual `coder create`
step required. `reap_coder_workspaces` is the TTL-based idle-workspace
reaper, meant to run on a Temporal Schedule via
`reaper_workflow.WorkspaceReaperWorkflow`.

Naturally idempotent by design (resolve-or-create keyed on workspace
name) — unlike `demo/activities.py`'s pattern, no separate
idempotency-state file is needed here.
"""

from __future__ import annotations

import asyncio
import re
from datetime import datetime, timezone

from temporalio import activity

from demo.coder_client import CoderAPIError, CoderClient
from demo.config import (
    CODER_CREATE_TIMEOUT_SECONDS,
    CODER_URL,
    CODER_WORKSPACE_API_TOKEN,
    CODER_WORKSPACE_OWNER,
    CODER_WORKSPACE_REAP_ACTION,
    CODER_WORKSPACE_TEMPLATE,
    CODER_WORKSPACE_TTL_MINUTES,
)

# Coder workspace names are capped at 32 characters server-side (a
# generic validation error otherwise — see AGENTS.md's recorded Issue #17
# lesson). `tw-` prefix reserves the namespace for Temporal-owned
# workspaces so the reaper can scope its listing to a single owner
# (`temporal-svc`) instead of scanning every workspace on the server.
NAME_PATTERN = re.compile(r"^tw-[a-z0-9-]{1,29}$")
POLL_INTERVAL_SECONDS = 5.0


def validate_workspace_name(name: str) -> str | None:
    """Returns an error string if `name` is invalid, else None."""
    if len(name) > 32:
        return f"workspace name {name!r} exceeds Coder's 32-char cap ({len(name)} chars)"
    if not NAME_PATTERN.match(name):
        return (
            f"workspace name {name!r} must match {NAME_PATTERN.pattern!r} "
            "(tw- prefix, lowercase alphanumerics/hyphens only)"
        )
    return None


def container_name_for(owner: str, name: str) -> str:
    """Byte-for-byte the same convention verified live in Issue #49:
    `coder-<owner>-<workspace-name-lowercased>`, matching
    `coder/templates/*/main.tf`'s `name =
    "coder-${owner}-${lower(workspace)}"`."""
    return f"coder-{owner}-{name.lower()}"


# Issue #50: every `coder_parameter` of the `docker-standard` template
# (dir `coder/templates/docker-workspace/main.tf`) must be passed
# explicitly, or workspace creation hangs with an opaque "prepare build:
# EOF" (documented in AGENTS.md and Issue #17). Verified directly against
# that Terraform file: exactly two parameters, `github_token` (default
# "") and `agent_capable` (default "false").
DEFAULT_RICH_PARAMETER_VALUES = [
    {"name": "github_token", "value": ""},
    {"name": "agent_capable", "value": "false"},
]


@activity.defn(name="ensure_coder_workspace")
async def ensure_coder_workspace(name: str) -> dict:
    """Resolve-or-create a Temporal-owned Coder workspace named `name`
    (owned by `CODER_WORKSPACE_OWNER`), polling until its latest build
    reaches `status == "running"` or `CODER_CREATE_TIMEOUT_SECONDS`
    elapses. Fails closed: any error is returned as a structured
    `{"ok": False, "error": ...}` dict, never raised, matching
    `run_build_command`'s existing contract."""
    if not CODER_WORKSPACE_API_TOKEN:
        return {
            "ok": False,
            "workspace_id": None,
            "container_name": None,
            "created": False,
            "error": "coder token not configured",
        }

    name_error = validate_workspace_name(name)
    if name_error:
        return {
            "ok": False,
            "workspace_id": None,
            "container_name": None,
            "created": False,
            "error": name_error,
        }

    owner = CODER_WORKSPACE_OWNER
    container_name = container_name_for(owner, name)

    async with CoderClient(CODER_URL, CODER_WORKSPACE_API_TOKEN) as client:
        try:
            workspace = await client.get_workspace(owner, name)
            created = False
            if workspace is None:
                org_id = await client.default_organization_id()
                version_id = await client.template_version_id(
                    org_id, CODER_WORKSPACE_TEMPLATE
                )
                workspace = await client.create_workspace(
                    org_id,
                    owner,
                    name,
                    version_id,
                    DEFAULT_RICH_PARAMETER_VALUES,
                )
                created = True

            workspace_id = workspace["id"]
            status = workspace.get("latest_build", {}).get("status")

            # A resolved-but-stopped workspace needs an explicit start —
            # resolve-or-create alone does not restart it.
            if status in ("stopped", "canceled", "failed", "deleted"):
                if status == "deleted":
                    return {
                        "ok": False,
                        "workspace_id": workspace_id,
                        "container_name": container_name,
                        "created": created,
                        "error": f"workspace {name!r} was deleted; retry with a new name",
                    }
                await client.start_workspace(workspace_id)

            elapsed = 0.0
            while elapsed < CODER_CREATE_TIMEOUT_SECONDS:
                workspace = await client.get_workspace_by_id(workspace_id)
                status = workspace.get("latest_build", {}).get("status")
                activity.heartbeat(status)
                if status == "running":
                    return {
                        "ok": True,
                        "workspace_id": workspace_id,
                        "container_name": container_name,
                        "created": created,
                        "error": None,
                    }
                if status in ("failed", "canceled"):
                    return {
                        "ok": False,
                        "workspace_id": workspace_id,
                        "container_name": container_name,
                        "created": created,
                        "error": f"workspace build ended with status={status!r}",
                    }
                await asyncio.sleep(POLL_INTERVAL_SECONDS)
                elapsed += POLL_INTERVAL_SECONDS

            return {
                "ok": False,
                "workspace_id": workspace_id,
                "container_name": container_name,
                "created": created,
                "error": f"timed out after {CODER_CREATE_TIMEOUT_SECONDS}s waiting for status=running",
            }
        except CoderAPIError as exc:
            return {
                "ok": False,
                "workspace_id": None,
                "container_name": container_name,
                "created": False,
                "error": str(exc),
            }


def _idle_minutes(last_used_at: str) -> float:
    """`last_used_at` is an RFC3339 timestamp from the Coder API."""
    parsed = datetime.fromisoformat(last_used_at.replace("Z", "+00:00"))
    now = datetime.now(timezone.utc)
    return (now - parsed).total_seconds() / 60.0


@activity.defn(name="reap_coder_workspaces")
async def reap_coder_workspaces() -> dict:
    """List `CODER_WORKSPACE_OWNER`'s workspaces, stop (default) or
    delete (`CODER_WORKSPACE_REAP_ACTION=delete`) any past
    `CODER_WORKSPACE_TTL_MINUTES` idle. Fail-closed per-item: one
    failure must not abandon the rest."""
    if not CODER_WORKSPACE_API_TOKEN:
        return {"inspected": 0, "reaped": [], "skipped": [], "error": "coder token not configured"}

    reaped: list[dict] = []
    skipped: list[dict] = []
    owner = CODER_WORKSPACE_OWNER

    async with CoderClient(CODER_URL, CODER_WORKSPACE_API_TOKEN) as client:
        try:
            workspaces = await client.list_workspaces(owner)
        except CoderAPIError as exc:
            return {"inspected": 0, "reaped": [], "skipped": [], "error": str(exc)}

        for workspace in workspaces:
            name = workspace.get("name", "<unknown>")
            last_used_at = workspace.get("last_used_at")
            latest_status = workspace.get("latest_build", {}).get("status")
            try:
                if not last_used_at:
                    skipped.append({"name": name, "reason": "no last_used_at"})
                    continue
                idle_minutes = _idle_minutes(last_used_at)
                if idle_minutes < CODER_WORKSPACE_TTL_MINUTES:
                    skipped.append({"name": name, "reason": f"idle {idle_minutes:.1f}m < TTL"})
                    continue
                if latest_status not in ("running", "stopped", "failed"):
                    skipped.append({"name": name, "reason": f"status={latest_status!r} not reapable"})
                    continue

                workspace_id = workspace["id"]
                if CODER_WORKSPACE_REAP_ACTION == "delete":
                    if latest_status == "running":
                        await client.stop_workspace(workspace_id)
                    await client.delete_workspace(workspace_id)
                    action = "delete"
                else:
                    if latest_status != "running":
                        skipped.append({"name": name, "reason": "already stopped"})
                        continue
                    await client.stop_workspace(workspace_id)
                    action = "stop"

                reaped.append({"name": name, "action": action, "idle_minutes": idle_minutes})
                activity.heartbeat(f"reaped {name}")
            except CoderAPIError as exc:
                skipped.append({"name": name, "reason": f"error: {exc}"})
            except Exception as exc:  # noqa: BLE001 - fail-closed per-item
                skipped.append({"name": name, "reason": f"unexpected error: {exc}"})

    return {"inspected": len(workspaces), "reaped": reaped, "skipped": skipped}
