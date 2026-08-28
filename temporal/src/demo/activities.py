"""Activities for the M8 durable-orchestration demo.

Both Activities are keyed by Workflow Run ID + Activity ID for idempotency
(docs.temporal.io/best-practices/error-handling#design-activities-for-idempotence):
that combination stays consistent across retries of the *same* Activity
while remaining unique across Workflow Executions, which is what makes the
worker-kill Manual E2E Test a meaningful durability proof rather than a
lucky no-op (a retried Activity replays its cached result instead of
re-running its side effect).

State is persisted to a JSON file on a named volume (not just in-process
memory) so idempotency also survives the worker *container* being killed
and recreated, not only in-process retries.
"""

import json
import os
import pathlib

from temporalio import activity
from temporalio.exceptions import ApplicationError

STATE_PATH = pathlib.Path(
    os.environ.get("DEMO_STATE_PATH", "/var/lib/demo-worker/idempotency.json")
)


def _load_state() -> dict:
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text())
    return {}


def _save_state(state: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state))


def _idempotency_key(activity_name: str) -> str:
    info = activity.info()
    return f"{info.workflow_run_id}:{info.activity_id}:{activity_name}"


@activity.defn(name="prepare_build")
async def prepare_build(build_id: str) -> str:
    if not build_id or not build_id.strip():
        # Permanent-failure category: malformed input can never succeed on
        # retry, so fail fast (non_retryable=True) instead of burning the
        # RetryPolicy's attempts on something that will never work.
        raise ApplicationError(
            "prepare_build received an empty build_id",
            non_retryable=True,
        )

    key = _idempotency_key("prepare_build")
    state = _load_state()
    cached = state.get(key)
    if cached is not None:
        activity.logger.info(
            "prepare_build: idempotent replay for key=%s, returning cached result",
            key,
        )
        return cached

    result = f"prepared:{build_id}"
    state[key] = result
    _save_state(state)
    return result


@activity.defn(name="verify_build")
async def verify_build(prepared: str) -> str:
    key = _idempotency_key("verify_build")
    state = _load_state()
    cached = state.get(key)
    if cached is not None:
        activity.logger.info(
            "verify_build: idempotent replay for key=%s, returning cached result",
            key,
        )
        return cached

    result = f"verified:{prepared}"
    state[key] = result
    _save_state(state)
    return result
