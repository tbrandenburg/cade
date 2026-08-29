"""Activities for the M15 end-to-end scenario: reserve a simulated device,
run its test, retrieve logs, release it. Each Activity is a thin wrapper
around one `lab_client` MCP tool call — Temporal's own retry policy handles
transient MCP/network failures (the lab-sim service itself is already
idempotent per-reservation, see `mcp/lab-sim/src/lab_sim/devices.py`).
"""

from temporalio import activity

from demo import lab_client


@activity.defn(name="reserve_lab_device")
async def reserve_lab_device(device_id: str) -> str:
    result = await lab_client.reserve_device(device_id)
    activity.logger.info("reserve_lab_device: device=%s -> %s", device_id, result)
    return result["reservation_id"]


@activity.defn(name="run_lab_test")
async def run_lab_test(reservation_id: str) -> dict[str, str]:
    result = await lab_client.run_test(reservation_id)
    activity.logger.info("run_lab_test: reservation=%s -> %s", reservation_id, result)
    return result


@activity.defn(name="retrieve_lab_logs")
async def retrieve_lab_logs(reservation_id: str) -> list[str]:
    logs = await lab_client.get_logs(reservation_id)
    activity.logger.info(
        "retrieve_lab_logs: reservation=%s lines=%d", reservation_id, len(logs)
    )
    return logs


@activity.defn(name="release_lab_device")
async def release_lab_device(reservation_id: str) -> str:
    result = await lab_client.release_device(reservation_id)
    activity.logger.info("release_lab_device: reservation=%s -> %s", reservation_id, result)
    return result
