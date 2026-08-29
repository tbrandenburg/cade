"""M15 Complete End-to-End Scenario: the durable Temporal workflow that
orchestrates the Lab/Device API capability call (M11, governed by M12's
OPA policy) — reserve simulated device -> wait -> run simulated test ->
retrieve logs -> release device — and returns a structured result for the
agent evaluation step (Step 7) to read.

This is deliberately a *separate* workflow from `DemoDurableWorkflow`
(M8's generic build-durability proof): M15 needs a real Lab/Device API
capability call, not another prepare/verify build simulation.
"""

import json
from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from demo.e2e_activities import (
        release_lab_device,
        reserve_lab_device,
        retrieve_lab_logs,
        run_lab_test,
    )

# "wait" per the plan's step 4 (reserve simulated device -> wait -> run
# simulated test -> retrieve logs) — kept short for a fast, deterministic
# CI/manual run; the durability guarantee (Event History, not worker
# memory) is already proven by M8's DemoDurableWorkflow.
WAIT_DURATION = timedelta(seconds=5)
ACTIVITY_TIMEOUT = timedelta(seconds=30)
LAB_RETRY_POLICY = RetryPolicy(
    backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=10),
    maximum_attempts=5,
)


@workflow.defn(name="EmbeddedValidationWorkflow")
class EmbeddedValidationWorkflow:
    @workflow.run
    async def run(self, device_id: str) -> str:
        reservation_id = await workflow.execute_activity(
            reserve_lab_device,
            device_id,
            start_to_close_timeout=ACTIVITY_TIMEOUT,
            retry_policy=LAB_RETRY_POLICY,
        )

        await workflow.sleep(WAIT_DURATION)

        test_result = await workflow.execute_activity(
            run_lab_test,
            reservation_id,
            start_to_close_timeout=ACTIVITY_TIMEOUT,
            retry_policy=LAB_RETRY_POLICY,
        )

        logs = await workflow.execute_activity(
            retrieve_lab_logs,
            reservation_id,
            start_to_close_timeout=ACTIVITY_TIMEOUT,
            retry_policy=LAB_RETRY_POLICY,
        )

        release_result = await workflow.execute_activity(
            release_lab_device,
            reservation_id,
            start_to_close_timeout=ACTIVITY_TIMEOUT,
            retry_policy=LAB_RETRY_POLICY,
        )

        return json.dumps(
            {
                "device_id": device_id,
                "reservation_id": reservation_id,
                "test_result": test_result,
                "logs": logs,
                "release_result": release_result,
            }
        )
