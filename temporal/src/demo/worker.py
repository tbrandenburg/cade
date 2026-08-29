"""Temporal worker entrypoint for the M8 durable-orchestration demo.

Graceful shutdown, not a bare process kill, on the happy path: installs
SIGINT/SIGTERM handlers that cancel the running worker task rather than
exiting immediately, matching the official worker best-practices doc's
"Manage scale-down safely" guidance. The *deliberate* hard-kill
(`docker kill`) used to prove durability in the Manual E2E Test is a
separate, intentional test path, not the normal stop path.
"""

import asyncio
import logging
import signal
from datetime import timedelta

from temporalio.client import Client
from temporalio.runtime import PrometheusConfig, Runtime, TelemetryConfig
from temporalio.worker import Worker

from demo.activities import prepare_build, verify_build
from demo.config import (
    METRICS_BIND_ADDRESS,
    TASK_QUEUE,
    TEMPORAL_ADDRESS,
    TEMPORAL_NAMESPACE,
)
from demo.e2e_activities import (
    release_lab_device,
    reserve_lab_device,
    retrieve_lab_logs,
    run_lab_test,
)
from demo.e2e_workflow import EmbeddedValidationWorkflow
from demo.workflows import DemoDurableWorkflow

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("demo.worker")


def _build_runtime() -> Runtime | None:
    """M13 Observability: export the Temporal SDK's built-in metrics
    (workflow/activity counters backing the "Temporal activity count" and
    "workflow failures" dashboard panels) via a native Prometheus HTTP
    endpoint - see demo/config.py for why this bypasses otel-collector's
    OTLP path. Returns None (SDK default runtime, no telemetry export) if
    METRICS_BIND_ADDRESS is unset, e.g. for a standalone test run without
    the observability stack up."""
    if not METRICS_BIND_ADDRESS:
        return None
    return Runtime(
        telemetry=TelemetryConfig(
            metrics=PrometheusConfig(bind_address=METRICS_BIND_ADDRESS)
        )
    )


async def run_worker() -> None:
    client = await Client.connect(
        TEMPORAL_ADDRESS, namespace=TEMPORAL_NAMESPACE, runtime=_build_runtime()
    )
    worker = Worker(
        client,
        task_queue=TASK_QUEUE,
        workflows=[DemoDurableWorkflow, EmbeddedValidationWorkflow],
        activities=[
            prepare_build,
            verify_build,
            reserve_lab_device,
            run_lab_test,
            retrieve_lab_logs,
            release_lab_device,
        ],
        graceful_shutdown_timeout=timedelta(seconds=5),
    )

    logger.info(
        "worker starting: address=%s namespace=%s task_queue=%s",
        TEMPORAL_ADDRESS,
        TEMPORAL_NAMESPACE,
        TASK_QUEUE,
    )

    loop = asyncio.get_running_loop()
    run_task = asyncio.ensure_future(worker.run())

    def _request_shutdown() -> None:
        logger.info("shutdown signal received, cancelling worker run loop")
        run_task.cancel()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _request_shutdown)

    try:
        await run_task
    except asyncio.CancelledError:
        logger.info("worker stopped")


def main() -> None:
    asyncio.run(run_worker())


if __name__ == "__main__":
    main()
