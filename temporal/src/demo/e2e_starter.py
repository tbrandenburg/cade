"""Starter (client) entrypoint for the M15 end-to-end scenario. Starts one
execution of `EmbeddedValidationWorkflow` against a simulated device and
either prints the workflow/run ID immediately or waits for the structured
JSON result with --wait (used by scripts/e2e-m15.sh Step 4-6).
"""

import argparse
import asyncio
import uuid

from temporalio.client import Client

from demo.config import TASK_QUEUE, TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE
from demo.e2e_workflow import EmbeddedValidationWorkflow


async def start(device_id: str, workflow_id: str, wait: bool) -> None:
    client = await Client.connect(TEMPORAL_ADDRESS, namespace=TEMPORAL_NAMESPACE)
    handle = await client.start_workflow(
        EmbeddedValidationWorkflow.run,
        device_id,
        id=workflow_id,
        task_queue=TASK_QUEUE,
    )
    print(f"workflow_id={handle.id} run_id={handle.result_run_id}")

    if wait:
        result = await handle.result()
        print(f"result={result}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--device-id", default="ecu-demo-01", help="lab-sim device id to reserve"
    )
    parser.add_argument(
        "--workflow-id",
        default=None,
        help="workflow id (defaults to a fresh unique id)",
    )
    parser.add_argument(
        "--wait",
        action="store_true",
        help="block until the workflow completes and print its structured result",
    )
    args = parser.parse_args()
    workflow_id = args.workflow_id or f"embedded-validation-{uuid.uuid4().hex[:8]}"
    asyncio.run(start(args.device_id, workflow_id, args.wait))


if __name__ == "__main__":
    main()
