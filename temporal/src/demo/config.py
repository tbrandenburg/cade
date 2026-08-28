"""Env-injected connection config, read once at import.

Pattern reused from `tbrandenburg/temporal-sandbox`'s `src/sandbox/config.py`
(see M8 step notes): read connection details from the environment with sane
localhost defaults, so both the starter and the worker import the same
values instead of hardcoding `localhost:7233` anywhere.
"""

import os

# NOTE: use the literal IPv4 address, never bare "localhost" — on hosts
# where "localhost" resolves to "::1" (IPv6) first, the Temporal server
# binds IPv4 only, producing a connection failure that looks like "server
# isn't running" when it's actually a resolution quirk (M8 step notes).
TEMPORAL_ADDRESS = os.environ.get("TEMPORAL_ADDRESS", "127.0.0.1:7233")
TEMPORAL_NAMESPACE = os.environ.get("TEMPORAL_NAMESPACE", "default")

# Shared Task Queue name constant. A Client/Worker Task Queue name mismatch
# does not error — the workflow just silently never gets picked up. Define
# it once here and import it in both the starter and the worker.
TASK_QUEUE = os.environ.get("DEMO_TASK_QUEUE", "demo-durable-workflow")
