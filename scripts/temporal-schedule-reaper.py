#!/usr/bin/env python3
"""Issue #50: create (or idempotently update) the Temporal Schedule that
runs `WorkspaceReaperWorkflow` every 15 minutes.

Designed to run with `demo`'s dependencies available on `PYTHONPATH` (the
`cade/temporal-worker:latest` image already has `temporalio` installed
and `PYTHONPATH=/app/src` set) — see `make temporal-reaper-schedule`,
which mounts this file into that image and runs it there rather than
requiring a separate local Python environment.

Idempotent: `client.create_schedule(...)` raises
`ScheduleAlreadyRunningError` if the schedule ID already exists; this
script catches that and instead calls `handle.update(...)` so re-running
it (e.g. from `make up`) is always safe.
"""

import asyncio
from datetime import timedelta

from temporalio.client import (
    Client,
    Schedule,
    ScheduleActionStartWorkflow,
    ScheduleAlreadyRunningError,
    ScheduleIntervalSpec,
    ScheduleOverlapPolicy,
    SchedulePolicy,
    ScheduleSpec,
    ScheduleState,
    ScheduleUpdate,
)

from demo.config import TASK_QUEUE, TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE
from demo.reaper_workflow import WorkspaceReaperWorkflow

SCHEDULE_ID = "workspace-reaper-schedule"
INTERVAL_MINUTES = 15


def _build_schedule() -> Schedule:
    action = ScheduleActionStartWorkflow(
        WorkspaceReaperWorkflow.run,
        id="workspace-reaper-workflow",
        task_queue=TASK_QUEUE,
    )
    spec = ScheduleSpec(
        intervals=[ScheduleIntervalSpec(every=timedelta(minutes=INTERVAL_MINUTES))]
    )
    return Schedule(
        action=action,
        spec=spec,
        policy=SchedulePolicy(overlap=ScheduleOverlapPolicy.SKIP),
        state=ScheduleState(paused=False),
    )


async def main() -> None:
    client = await Client.connect(TEMPORAL_ADDRESS, namespace=TEMPORAL_NAMESPACE)
    schedule = _build_schedule()

    try:
        await client.create_schedule(SCHEDULE_ID, schedule, trigger_immediately=False)
        print(f"created schedule {SCHEDULE_ID!r} (every {INTERVAL_MINUTES}m, overlap=SKIP)")
    except ScheduleAlreadyRunningError:
        handle = client.get_schedule_handle(SCHEDULE_ID)

        async def _updater(_input):
            return ScheduleUpdate(schedule=schedule)

        await handle.update(_updater)
        print(f"schedule {SCHEDULE_ID!r} already existed — updated in place")


if __name__ == "__main__":
    asyncio.run(main())
