"""Starter (client) entrypoint for the M8 durable-orchestration demo.

Starts one execution of DemoDurableWorkflow on the shared TASK_QUEUE and
either prints the workflow/run ID immediately (default — lets a script kill
the worker mid-timer) or waits for the result with --wait.
"""

import argparse
import asyncio
import uuid

from temporalio.client import Client

from demo.config import TASK_QUEUE, TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE
from demo.workflows import DemoDurableWorkflow


async def start(build_id: str, workflow_id: str, wait: bool) -> None:
    client = await Client.connect(TEMPORAL_ADDRESS, namespace=TEMPORAL_NAMESPACE)
    handle = await client.start_workflow(
        DemoDurableWorkflow.run,
        build_id,
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
        "--build-id", default=f"demo-{uuid.uuid4().hex[:8]}", help="build id passed to prepare_build"
    )
    parser.add_argument(
        "--workflow-id",
        default=None,
        help="workflow id (defaults to a fresh unique id)",
    )
    parser.add_argument(
        "--wait",
        action="store_true",
        help="block until the workflow completes and print its result",
    )
    args = parser.parse_args()
    workflow_id = args.workflow_id or f"demo-durable-workflow-{uuid.uuid4().hex[:8]}"
    asyncio.run(start(args.build_id, workflow_id, args.wait))


if __name__ == "__main__":
    main()
