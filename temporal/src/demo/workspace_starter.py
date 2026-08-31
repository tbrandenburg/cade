"""Starter (client) entrypoint for Issue #50: starts one execution of
`PersistentWorkspaceBuildWorkflow` for manual testing — mirrors
`demo.build_starter`'s structure.
"""

import argparse
import asyncio
import json
import uuid

from temporalio.client import Client

from demo.config import TASK_QUEUE, TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE
from demo.workspace_workflow import PersistentWorkspaceBuildWorkflow


async def start(
    name: str,
    image: str,
    command: list[str],
    workdir: str,
    workflow_id: str,
    wait: bool,
) -> None:
    client = await Client.connect(TEMPORAL_ADDRESS, namespace=TEMPORAL_NAMESPACE)
    handle = await client.start_workflow(
        PersistentWorkspaceBuildWorkflow.run,
        args=[name, image, command, workdir],
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
        "--name",
        required=True,
        help="Temporal-owned workspace name (must match ^tw-[a-z0-9-]{1,29}$, <=32 chars total)",
    )
    parser.add_argument(
        "--image",
        default="cade/coder-workspace:latest",
        help="image used purely for the OPA build.authz check (not created)",
    )
    parser.add_argument(
        "--command",
        nargs="+",
        default=["echo", "hello"],
        help="command (and args) to run inside the resolved workspace container",
    )
    parser.add_argument(
        "--workdir",
        default="/home/coder",
        help="working directory inside the workspace container (default: /home/coder)",
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
    workflow_id = args.workflow_id or f"workspace-workflow-{uuid.uuid4().hex[:8]}"
    asyncio.run(
        start(args.name, args.image, args.command, args.workdir, workflow_id, args.wait)
    )


if __name__ == "__main__":
    main()
