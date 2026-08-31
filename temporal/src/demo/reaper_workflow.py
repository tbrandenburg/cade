"""Issue #50 Workflow: `WorkspaceReaperWorkflow` — single
`reap_coder_workspaces` Activity call, meant to run on a Temporal Schedule
(see `scripts/temporal-schedule-reaper.py`, 15-minute interval)."""

from datetime import timedelta

from temporalio import workflow

with workflow.unsafe.imports_passed_through():
    from demo.workspace_activity import reap_coder_workspaces

ACTIVITY_TIMEOUT = timedelta(minutes=5)


@workflow.defn(name="WorkspaceReaperWorkflow")
class WorkspaceReaperWorkflow:
    @workflow.run
    async def run(self) -> dict:
        return await workflow.execute_activity(
            reap_coder_workspaces,
            start_to_close_timeout=ACTIVITY_TIMEOUT,
        )
