"""Starter (client) entrypoint for the Issue #5 MVP: starts one execution
of `BuildWorkflow` for manual testing — mirrors `demo.e2e_starter`'s
structure (see that file), scoped to the new build-command capability.
"""

import argparse
import asyncio
import json
import uuid

from temporalio.client import Client

from demo.build_workflow import TEMPLATE_IMAGES, BuildWorkflow
from demo.config import TASK_QUEUE, TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE


async def start(
    image: str | None,
    command: list[str],
    workflow_id: str,
    wait: bool,
    template: str | None = None,
) -> None:
    client = await Client.connect(TEMPORAL_ADDRESS, namespace=TEMPORAL_NAMESPACE)
    handle = await client.start_workflow(
        BuildWorkflow.run,
        args=[image, command, "/workspace", template],
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
        default=None,
        help=(
            "explicit image to run the command in; takes precedence over "
            "--template if both are given. Defaults to "
            "cade/coder-workspace:latest if neither --image nor --template "
            "is given (backward-compatible default)."
        ),
    )
    parser.add_argument(
        "--template",
        default=None,
        choices=sorted(TEMPLATE_IMAGES),
        help=(
            "Coder workspace template name to resolve to its pre-built "
            "image via a lookup table (ignored if --image is also given)"
        ),
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
    asyncio.run(start(args.image, args.command, workflow_id, args.wait, args.template))


if __name__ == "__main__":
    main()
