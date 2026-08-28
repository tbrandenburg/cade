"""Workflow and Activity definitions for the M8 durable-orchestration demo.

start -> activity prepare_build -> wait 30s -> activity verify_build -> finish
"""

from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from demo.activities import prepare_build, verify_build

# The Timer below is at least a full 30s per the step requirement, but kept
# short enough that a human/script can reliably `docker kill` the worker
# mid-sleep during the Manual E2E Test without a long wait.
TIMER_DURATION = timedelta(seconds=30)

# Explicit Activity timeout — required, not optional: the Python SDK will
# not schedule an Activity without at least one timeout.
ACTIVITY_TIMEOUT = timedelta(seconds=30)


@workflow.defn(name="DemoDurableWorkflow")
class DemoDurableWorkflow:
    @workflow.run
    async def run(self, build_id: str) -> str:
        # Intermittent-failure category: space retries out instead of the
        # SDK default, so a rate-limited dependency isn't hammered.
        prepare_retry_policy = RetryPolicy(
            backoff_coefficient=2.0,
            maximum_interval=timedelta(seconds=10),
            maximum_attempts=5,
        )
        prepared = await workflow.execute_activity(
            prepare_build,
            build_id,
            start_to_close_timeout=ACTIVITY_TIMEOUT,
            retry_policy=prepare_retry_policy,
        )

        # Server-side state in the workflow's Event History (Temporal-DB),
        # not worker memory — surviving a worker restart during this sleep
        # is the M8 durability proof.
        await workflow.sleep(TIMER_DURATION)

        verified = await workflow.execute_activity(
            verify_build,
            prepared,
            start_to_close_timeout=ACTIVITY_TIMEOUT,
            retry_policy=RetryPolicy(maximum_attempts=3),
        )

        return f"{prepared} -> {verified}"
