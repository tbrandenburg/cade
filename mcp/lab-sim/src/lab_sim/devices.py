"""In-memory simulated ECU device fleet for the M11 Lab Simulator.

No physical hardware - `flash_device`/`run_test` simulate the corresponding
lifecycle step and append to a per-reservation log. State resets when the
process restarts; that is acceptable for a simulator (see step file: "Do not
use physical hardware yet... against simulated devices").

Reservation binding: `Reservation.caller_id` records who created the
reservation. Every mutating operation on an existing reservation
(`flash_device`, `run_test`, `get_logs`, `release_device`) must be called
with the same `caller_id` - passing the correct `reservation_id` alone is
*not* sufficient, per the MCP spec's "State Handle Hijacking" guidance.
"""

from __future__ import annotations

import secrets
import time
from dataclasses import dataclass, field


class DeviceNotFoundError(LookupError):
    pass


class DeviceUnavailableError(RuntimeError):
    pass


class ReservationNotFoundError(LookupError):
    pass


class ReservationOwnershipError(PermissionError):
    """Raised when a caller other than the reservation owner attempts to use
    a reservation ID. This is the check that prevents state-handle
    hijacking."""


@dataclass
class Device:
    device_id: str
    kind: str
    status: str = "available"  # available | reserved | flashed


@dataclass
class Reservation:
    reservation_id: str
    device_id: str
    caller_id: str
    logs: list[str] = field(default_factory=list)

    def log(self, message: str) -> None:
        self.logs.append(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {message}")


class LabSimulator:
    def __init__(self) -> None:
        self._devices: dict[str, Device] = {
            "ecu-demo-01": Device("ecu-demo-01", "engine-control-unit"),
            "ecu-demo-02": Device("ecu-demo-02", "engine-control-unit"),
            "bms-demo-01": Device("bms-demo-01", "battery-management-system"),
        }
        self._reservations: dict[str, Reservation] = {}

    def list_devices(self) -> list[dict[str, str]]:
        return [
            {"device": d.device_id, "kind": d.kind, "status": d.status}
            for d in self._devices.values()
        ]

    def reserve_device(self, device_id: str, caller_id: str) -> str:
        device = self._devices.get(device_id)
        if device is None:
            raise DeviceNotFoundError(f"unknown device: {device_id}")
        if device.status != "available":
            raise DeviceUnavailableError(f"device {device_id} is not available (status={device.status})")
        reservation_id = secrets.token_hex(8)
        device.status = "reserved"
        reservation = Reservation(reservation_id=reservation_id, device_id=device_id, caller_id=caller_id)
        reservation.log(f"reserved by {caller_id}")
        self._reservations[reservation_id] = reservation
        return reservation_id

    def _get_owned_reservation(self, reservation_id: str, caller_id: str) -> Reservation:
        reservation = self._reservations.get(reservation_id)
        if reservation is None:
            raise ReservationNotFoundError(f"unknown reservation: {reservation_id}")
        if reservation.caller_id != caller_id:
            raise ReservationOwnershipError(
                f"reservation {reservation_id} is not owned by caller {caller_id!r}"
            )
        return reservation

    def flash_device(self, reservation_id: str, caller_id: str) -> str:
        reservation = self._get_owned_reservation(reservation_id, caller_id)
        device = self._devices[reservation.device_id]
        device.status = "flashed"
        message = f"flashed {device.device_id} with simulated firmware image"
        reservation.log(message)
        return message

    def run_test(self, reservation_id: str, caller_id: str) -> dict[str, str]:
        reservation = self._get_owned_reservation(reservation_id, caller_id)
        device = self._devices[reservation.device_id]
        result = "pass"
        message = f"ran simulated test suite on {device.device_id}: result={result}"
        reservation.log(message)
        return {"device": device.device_id, "result": result}

    def get_logs(self, reservation_id: str, caller_id: str) -> list[str]:
        reservation = self._get_owned_reservation(reservation_id, caller_id)
        return list(reservation.logs)

    def release_device(self, reservation_id: str, caller_id: str) -> str:
        reservation = self._get_owned_reservation(reservation_id, caller_id)
        device = self._devices[reservation.device_id]
        device.status = "available"
        del self._reservations[reservation_id]
        return f"released {device.device_id}"


SIMULATOR = LabSimulator()
