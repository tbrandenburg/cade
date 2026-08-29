"""Starter (client) entrypoint for the Issue #5 MVP: starts one execution
of `BuildWorkflow` for manual testing — mirrors `demo.e2e_starter`'s
structure (see that file), scoped to the new build-command capability.
"""

import argparse
import asyncio
import json
import uuid

from temporalio.client import Client

from demo.build_workflow import BuildWorkflow
from demo.config import TASK_QUEUE, TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE


async def start(image: str, command: list[str], workflow_id: str, wait: bool) -> None:
    client = await Client.connect(TEMPORAL_ADDRESS, namespace=TEMPORAL_NAMESPACE)
    handle = await client.start_workflow(
        BuildWorkflow.run,
        args=[image, command],
        id=workflow_id,
        task_queue=TASK_QUEUE,
    )
    print(f"workflow_id={handle.id} run_id={handle.result_run_id}")

    if wait:
        result = await handle.result()
        print(f"result={json.dumps(result)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--image",
        default="cade/coder-workspace:latest",
        help="image to run the command in",
    )
    parser.add_argument(
        "--command",
        nargs="+",
        default=["echo", "hello"],
        help="command (and args) to run inside the container",
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
    workflow_id = args.workflow_id or f"build-workflow-{uuid.uuid4().hex[:8]}"
    asyncio.run(start(args.image, args.command, workflow_id, args.wait))


if __name__ == "__main__":
    main()
