"""Issue #5 MVP Workflow: run a single build/test command inside a
predefined workspace image via `run_build_command`
(`demo/build_activity.py`). Deliberately separate from
`DemoDurableWorkflow` (M8's generic build simulation, no real container)
and `EmbeddedValidationWorkflow` (M15's lab-sim capability call) — this is
the only workflow that actually executes a command inside a container
built from the same image Coder workspaces run.
"""

from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from demo.build_activity import run_build_command

ACTIVITY_TIMEOUT = timedelta(minutes=5)
# No retries by default: a failing build/test command is a legitimate
# result to return, not a transient fault to retry.
BUILD_RETRY_POLICY = RetryPolicy(maximum_attempts=1)


@workflow.defn(name="BuildWorkflow")
class BuildWorkflow:
    @workflow.run
    async def run(self, image: str, command: list[str], workdir: str = "/workspace") -> dict:
        return await workflow.execute_activity(
            run_build_command,
            args=[image, command, workdir],
            start_to_close_timeout=ACTIVITY_TIMEOUT,
            retry_policy=BUILD_RETRY_POLICY,
        )
