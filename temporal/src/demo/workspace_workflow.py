"""Issue #50 Workflow: `PersistentWorkspaceBuildWorkflow` — resolve-or-
create a Temporal-owned Coder workspace, then reuse the existing,
UNCHANGED `run_build_command` Activity (`demo/build_activity.py`) against
its resolved container name. `/home/coder` (not `/workspace`) is the
default workdir here — a real Coder workspace container has no
`/workspace` directory (see AGENTS.md's Issue #49 lesson)."""

from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from demo.build_activity import run_build_command
    from demo.workspace_activity import ensure_coder_workspace

ENSURE_ACTIVITY_TIMEOUT = timedelta(minutes=12)
BUILD_ACTIVITY_TIMEOUT = timedelta(minutes=5)
BUILD_RETRY_POLICY = RetryPolicy(maximum_attempts=2)


@workflow.defn(name="PersistentWorkspaceBuildWorkflow")
class PersistentWorkspaceBuildWorkflow:
    @workflow.run
    async def run(
        self,
        name: str,
        image: str,
        command: list[str],
        workdir: str = "/home/coder",
    ) -> dict:
        ensure_result = await workflow.execute_activity(
            ensure_coder_workspace,
            args=[name],
            start_to_close_timeout=ENSURE_ACTIVITY_TIMEOUT,
            heartbeat_timeout=timedelta(seconds=30),
        )
        if not ensure_result.get("ok"):
            return {"ok": False, "stage": "ensure_coder_workspace", "error": ensure_result.get("error")}

        build_result = await workflow.execute_activity(
            run_build_command,
            args=[image, command, workdir, ensure_result["container_name"]],
            start_to_close_timeout=BUILD_ACTIVITY_TIMEOUT,
            retry_policy=BUILD_RETRY_POLICY,
        )
        return {"ok": build_result.get("ok"), "stage": "run_build_command", "ensure": ensure_result, "build": build_result}
